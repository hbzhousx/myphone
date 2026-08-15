#!/usr/bin/env bash
# ============================================================
# MyPhone 服务器依赖安装脚本（在阿里云轻量服务器上以 root 执行一次）
#
# 功能：安装 PostgreSQL / Redis / Nginx / coturn，
#       生成随机密码并写入 /etc/myphone/myphone.env，
#       配置 coturn 并启动，配置主机防火墙（尽力而为）。
#
# 前置：已通过 SSH 登录服务器，具备 root 权限（或 sudo）。
# 用法：sudo bash install-deps.sh [公网IP]
#       [公网IP] 可选；未传则尝试自动探测，用于 coturn external-ip。
# ============================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "错误：请用 root 运行（sudo bash install-deps.sh）" >&2; exit 1; }

# ---------- 1. 检测发行版 ----------
if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
else
    echo "错误：仅支持 apt/dnf/yum 系发行版（Ubuntu / Debian / Alibaba Cloud Linux / CentOS）" >&2
    exit 1
fi
echo "==> 检测到包管理器: $PM"

# ---------- 2. 公网 IP 与随机密码 ----------
PUBLIC_IP="${1:-${MYPHONE_PUBLIC_IP:-}}"
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(curl -s -m 3 ifconfig.me 2>/dev/null || true)"
fi
DB_PASSWORD="$(openssl rand -hex 16)"
TURN_PASSWORD="$(openssl rand -hex 16)"
echo "==> 公网 IP: ${PUBLIC_IP:-未探测到（跳过 external-ip，可稍后手动补 /etc/turnserver.conf）}"
echo "==> 已生成数据库密码与 TURN 密码"

# ---------- 3. 安装软件包 ----------
case "$PM" in
    apt)
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            postgresql redis-server nginx coturn apache2-utils openssl curl
        PG_SERVICE="postgresql"
        REDIS_SERVICE="redis-server"
        ;;
    dnf|yum)
        "$PM" install -y postgresql-server postgresql redis nginx coturn httpd-tools openssl curl
        PG_SERVICE="postgresql"
        REDIS_SERVICE="redis"
        # PostgreSQL 首次初始化（已初始化则跳过）。
        # 注意：RHEL 系 RPM 会预建空 /var/lib/pgsql/data 目录，
        # 因此不能只看目录是否存在，须看是否已有 PG_VERSION 文件。
        if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
            postgresql-setup --initdb
        fi
        # dnf 系默认 pg_hba 为 ident，改为密码认证（scram-sha-256）
        PGHBA=$(find /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1)
        if [ -n "$PGHBA" ]; then
            sed -i 's/^\(host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\)ident/\1scram-sha-256/' "$PGHBA"
            sed -i 's/^\(host\s\+all\s\+all\s\+::1\/128\s\+\)ident/\1scram-sha-256/' "$PGHBA"
        fi
        ;;
esac

# ---------- 4. 生成服务器环境变量 ----------
mkdir -p /etc/myphone
cat > /etc/myphone/myphone.env <<EOF
DATABASE_URL=postgres://myphone:${DB_PASSWORD}@127.0.0.1:5432/myphone?sslmode=disable
REDIS_ADDR=127.0.0.1:6379
PORT=8080
MYPHONE_DB_PASSWORD=${DB_PASSWORD}
MYPHONE_TURN_PASSWORD=${TURN_PASSWORD}
MYPHONE_PUBLIC_IP=${PUBLIC_IP}
MYPHONE_ATTACHMENT_DIR=/opt/myphone/attachments
EOF
chmod 600 /etc/myphone/myphone.env
echo "==> 已生成 /etc/myphone/myphone.env"

# ---------- 5. 启动 PostgreSQL / Redis ----------
systemctl enable --now "$PG_SERVICE" "$REDIS_SERVICE"
systemctl restart "$PG_SERVICE" "$REDIS_SERVICE"
echo "==> PostgreSQL($PG_SERVICE) / Redis($REDIS_SERVICE) 已启动"

# ---------- 6. 配置并启动 coturn ----------
# 配置路径按发行版区分：
#   Debian/Ubuntu: /etc/turnserver.conf
#   RHEL 系 (Alibaba Cloud Linux/CentOS): /etc/coturn/turnserver.conf（systemd 单元固定读取）
if [ -d /etc/coturn ]; then
    TURN_CONF=/etc/coturn/turnserver.conf
else
    TURN_CONF=/etc/turnserver.conf
fi
cat > "$TURN_CONF" <<EOF
# MyPhone 自建 TURN 服务器（阿里云轻量）
listening-port=3478
fingerprint
lt-cred-mech
user=myphone:${TURN_PASSWORD}
realm=myphone
# 配额与安全（注：coturn ≥4.5 已移除 no-loopback-peers，用 denied-peer-ip 代替）
total-quota=100
max-bps=1000000
denied-peer-ip=127.0.0.0/8
denied-peer-ip=::1
no-multicast-peers
stale-nonce
# 中继端口范围（阿里云安全组需放行 49152-65535/udp）
min-port=49152
max-port=65535
log-file=/var/log/turnserver.log
EOF
if [ -n "$PUBLIC_IP" ]; then
    echo "external-ip=${PUBLIC_IP}" >> "$TURN_CONF"
fi

# 日志文件权限：RHEL 系 coturn 以 coturn 用户运行，Debian 以 turnserver 用户运行，
# 需确保其可写（否则 coturn 无法写日志）
touch /var/log/turnserver.log
if id coturn >/dev/null 2>&1; then
    chown coturn:coturn /var/log/turnserver.log
elif id turnserver >/dev/null 2>&1; then
    chown turnserver:turnserver /var/log/turnserver.log
fi
chmod 640 /var/log/turnserver.log

# Ubuntu/Debian 的 coturn 默认禁用，需开启
if [ -f /etc/default/coturn ]; then
    sed -i 's/^#*TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
fi
systemctl enable --now coturn 2>/dev/null || true
systemctl restart coturn 2>/dev/null || true
echo "==> coturn 已配置（账号 myphone / 密码见 /etc/myphone/myphone.env 的 MYPHONE_TURN_PASSWORD）"

# ---------- 7. 主机防火墙（尽力而为；阿里云安全组是主控制） ----------
if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 3478/tcp
    ufw allow 3478/udp
    ufw allow 49152:65535/udp
    ufw --force enable
    echo "==> ufw 已配置并启用"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=ssh --add-service=http
    firewall-cmd --permanent --add-port=3478/tcp --add-port=3478/udp
    firewall-cmd --permanent --add-port=49152-65535/udp
    firewall-cmd --reload
    echo "==> firewalld 已配置"
else
    echo "!! 未发现 ufw/firewalld，请确保阿里云控制台安全组只放行：22, 80, 3478/tcp+udp, 49152-65535/udp"
fi

# ---------- 8. 提示 ----------
echo ""
echo "============================================================"
echo " 安装完成。下一步："
echo "   1) bash init-db.sh            # 初始化 PostgreSQL 库"
echo "   2) 把服务端二进制传到服务器后运行 deploy-server.sh"
echo "   3) 打包生产 APK 时，把 TURN 密码填入开发机 build.env："
echo "      MYPHONE_TURN_CREDENTIAL=${TURN_PASSWORD}"
echo "============================================================"
