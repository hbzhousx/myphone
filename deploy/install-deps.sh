#!/usr/bin/env bash
# ============================================================
# MyPhone 服务器依赖安装脚本（在生产服务器上以 sudo 执行一次）
# 生产服务器：demoserver（bear@59.175.112.234，SSH 端口 8006，路由器 DNAT 8006→22）
#
# 功能：安装 PostgreSQL 16(pgdg) / Redis / Nginx / coturn，
#       生成随机密码并写入 /etc/myphone/myphone.env，
#       配置 coturn（模板底本，含 server-relay）并启动，配置 ufw 防火墙。
#
# 前置：已通过 SSH 登录服务器，具备 sudo 权限。
# 用法：sudo bash install-deps.sh [公网IP] [内网IP]
#       公网IP 默认 59.175.112.234（NAT 后机器不能靠 ifconfig.me 探测）
#       内网IP 默认自动取默认路由源地址（demoserver 为 192.168.100.104）
#       也可用环境变量 MYPHONE_PUBLIC_IP / MYPHONE_LAN_IP 注入。
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

# ---------- 2. 公网 IP / 内网 IP 与随机密码 ----------
# demoserver 在 NAT 后（内网 192.168.100.104，公网 59.175.112.234 是路由器地址），
# ifconfig.me 探测不可靠，必须显式指定；coturn external-ip 用「公网IP/内网IP」双值形式。
PUBLIC_IP="${1:-${MYPHONE_PUBLIC_IP:-59.175.112.234}}"
LAN_IP="${2:-${MYPHONE_LAN_IP:-}}"
if [ -z "$LAN_IP" ]; then
    LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)"
fi
# 密码支持环境变量注入（重放/复现部署时保持一致），缺省随机生成。
DB_PASSWORD="${MYPHONE_DB_PASSWORD:-$(openssl rand -hex 16)}"
TURN_PASSWORD="${MYPHONE_TURN_PASSWORD:-$(openssl rand -hex 16)}"
BRIDGE_TOKEN="${MYPHONE_BRIDGE_TOKEN:-$(openssl rand -hex 24)}"
echo "==> 公网 IP: ${PUBLIC_IP}（coturn external-ip 前半）"
echo "==> 内网 IP: ${LAN_IP:-未探测到（external-ip 退化为单值形式）}"
echo "==> 已生成数据库密码与 TURN 密码"

# ---------- 3. 安装软件包 ----------
case "$PM" in
    apt)
        # 阿里云生产库是 PG13，apt 自带的 PG12 低于迁移要求 → 走 pgdg 源装 PG16。
        # 清华/USTC 镜像与 pgdg 主仓均已下架 focal-pgdg（20.04 EOL）；
        # pgdg 官方归档仓保留 focal-pgdg 套件（2026-08 实测 Release 200）。
        if ! apt-cache policy postgresql-16 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            echo "==> 配置 pgdg 归档 apt 源（PostgreSQL 16，focal）"
            echo "deb https://apt-archive.postgresql.org/pub/repos/apt focal-pgdg main" \
                > /etc/apt/sources.list.d/pgdg.list
            curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
                | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg 2>/dev/null \
                || curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
                | apt-key add - 2>/dev/null || true
        fi
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            postgresql-16 redis-server nginx coturn apache2-utils openssl curl
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
# ---- v1.50 AI 语音通话（媒体端点）----
# myphone-server 出站桥 → 本地媒体端点（同机回环即可）
AGENT_MEDIA_WS_URL=ws://127.0.0.1:8090/bridge
AGENT_BRIDGE_TOKEN=${BRIDGE_TOKEN}
# 媒体端点监听地址（仅本机回环，不直接暴露公网）
AGENT_LISTEN_ADDR=127.0.0.1:8090
# ---- v1.50+ 语音引擎：qwen-audio-agent Gateway + MiniCPM-o（demoserver 本地链路）----
# media-agent WebRTC 上行优先（手机 opus 原样透传到 Gateway 的 WebRTC 入口），
# 建连失败自动落回 WS Gateway 兜底 —— 两者指向同一 Gateway（3101）。
AGENT_WEBRTC_URL=http://127.0.0.1:3101
AGENT_GATEWAY_URL=ws://127.0.0.1:3101/api/realtime
AGENT_GATEWAY_SESSION_ID=user_personal
# ---- 后台 Agent（可选，让哪吒执行工具/多步任务，如"订机票/跑代码"）----
# AGENT_PROTOCOL=hermes
# HERMES_BIN=/usr/local/bin/hermes
# 外部 ASR/TTS/Agent（已接本地 MiniCPM-o 链路，留空；无 Gateway 时才回退本地回声）
# AGENT_ASR_URL=ws://asr.example.com/stream
# AGENT_TTS_URL=https://tts.example.com/synthesize
# AGENT_TEXT_URL=https://agent.example.com/chat
# 媒体端点 ICE（复用本机 coturn；media-agent 与 coturn 同机，走回环消除 NAT hairpin 依赖）
AGENT_STUN_URL=stun:127.0.0.1:3478
AGENT_TURN_URL=turn:127.0.0.1:3478
AGENT_TURN_USERNAME=myphone
AGENT_TURN_CREDENTIAL=${TURN_PASSWORD}
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
# 以 deploy/coturn/turnserver.conf 模板为底本（含关键的 server-relay 与私有段
# allowed-peer-ip —— 早期生成版缺这两组配置，会导致 relay→relay 不转发、
# 真机 host 候选 CreatePermission 403，跨网络通话不通）。
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/coturn/turnserver.conf"
if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$TURN_CONF"
else
    echo "!! 未找到模板 $TEMPLATE，退化为内置配置" >&2
    cat > "$TURN_CONF" <<'EOF'
# MyPhone 自建 TURN 服务器
listening-port=3478
fingerprint
lt-cred-mech
realm=myphone
total-quota=100
max-bps=1000000
no-multicast-peers
stale-nonce
no-cli
server-relay
allow-loopback-peers
allowed-peer-ip=10.0.0.0-10.255.255.255
allowed-peer-ip=172.16.0.0-172.31.255.255
allowed-peer-ip=192.168.0.0-192.168.255.255
allowed-peer-ip=100.64.0.0-100.127.255.255
min-port=49152
max-port=65535
log-file=/var/log/turnserver.log
EOF
fi
# focal 的 coturn 强校验：allow-loopback-peers 必须配非空 cli-password，
# 模板中的 no-cli 与之冲突（CONFIG ERROR 启动即退）→ 移除 no-cli 并注入
# cli-password（复用 TURN 密码即可，CLI 仅回环可达）。
sed -i '/^no-cli$/d' "$TURN_CONF"
echo "cli-password=${TURN_PASSWORD}" >> "$TURN_CONF"
# 注入账号与 external-ip（NAT 场景必须「公网IP/内网IP」双值形式）
echo "user=myphone:${TURN_PASSWORD}" >> "$TURN_CONF"
if [ -n "$PUBLIC_IP" ] && [ -n "$LAN_IP" ] && [ "$PUBLIC_IP" != "$LAN_IP" ]; then
    echo "external-ip=${PUBLIC_IP}/${LAN_IP}" >> "$TURN_CONF"
    # NAT 内网转发场景：显式钉死监听/中继地址（不配 coturn 会自动探测，
    # 可能选错网卡导致中继分配异常）
    echo "listening-ip=${LAN_IP}" >> "$TURN_CONF"
    echo "relay-ip=${LAN_IP}" >> "$TURN_CONF"
elif [ -n "$PUBLIC_IP" ]; then
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

# ---------- 7. 主机防火墙 ----------
# demoserver 无云安全组，ufw 是 8080/5432/6379/8090 等端口的唯一防线（默认 deny）。
# 注意：公网 SSH 走 8006，是路由器 DNAT 到本机 22 —— ufw 只认 22，放行 8006 无效。
# 其余公网可达性（80/3478/中继段）还依赖路由器把对应端口 DNAT 到本机内网 IP。
if command -v ufw >/dev/null 2>&1; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH公网8006映射的目标端口,防锁死'
    if [ -n "$LAN_IP" ]; then
        ufw allow from "${LAN_IP%.*}.0/24" to any port 22 proto tcp comment 'LAN SSH'
    fi
    ufw allow 80/tcp comment 'nginx myphone'
    ufw allow 3478/tcp comment 'TURN over TCP'
    ufw allow 3478/udp comment 'TURN over UDP'
    ufw allow 49152:65535/udp comment 'TURN relay range'
    ufw --force enable
    echo "==> ufw 已配置并启用（22/80/3478tcp+udp/49152-65535udp 放行，其余默认拒绝）"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=ssh --add-service=http
    firewall-cmd --permanent --add-port=3478/tcp --add-port=3478/udp
    firewall-cmd --permanent --add-port=49152-65535/udp
    firewall-cmd --reload
    echo "==> firewalld 已配置"
else
    echo "!! 未发现 ufw/firewalld，请手动只放行：22, 80, 3478/tcp+udp, 49152-65535/udp"
fi

# ---------- 8. 提示 ----------
echo ""
echo "============================================================"
echo " 安装完成。下一步："
echo "   1) bash init-db.sh            # 初始化 PostgreSQL 库"
echo "   2) 把服务端二进制传到服务器后运行 deploy-server.sh"
echo "   3) 打包生产 APK 时，把 TURN 密码填入开发机 deploy/.env.local："
echo "      MYPHONE_TURN_CREDENTIAL=${TURN_PASSWORD}"
echo "   4) 路由器需把 80/tcp、3478/tcp+udp、49152-65535/udp DNAT 到本机(${LAN_IP:-内网IP})"
echo "============================================================"
