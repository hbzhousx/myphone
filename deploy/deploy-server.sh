#!/usr/bin/env bash
# ============================================================
# MyPhone 服务端部署脚本（在阿里云轻量服务器上以 root 执行）
# 前置：
#   1) 已运行 install-deps.sh 与 init-db.sh
#   2) 服务端二进制已放在 /opt/myphone/myphone-server
#      （本地 build-server.sh 编译后 scp 上传）
# 功能：安装 systemd 单元、以 myphone 用户启动、配置 Nginx 反向代理
#       （HTTP 80 + WebSocket + 管理后台 Basic Auth）。
# 可选环境变量：MYPHONE_ADMIN_USER / MYPHONE_ADMIN_PASSWORD（管理后台账号密码）
# ============================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "错误：请用 root 运行（sudo bash deploy-server.sh）" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/opt/myphone"
BIN="$APP_DIR/myphone-server"
AGENT_BIN="$APP_DIR/media-agent"
ENV_FILE="/etc/myphone/myphone.env"
ADMIN_USER="${MYPHONE_ADMIN_USER:-admin}"

# ---------- 前置检查 ----------
[ -f "$BIN" ] || { echo "错误：未找到 $BIN" >&2; echo "请先在开发机运行 build-server.sh，再 scp 到服务器：" >&2; echo "  scp deploy/artifacts/myphone-server root@<公网IP>:/opt/myphone/myphone-server" >&2; exit 1; }
[ -f "$AGENT_BIN" ] || { echo "错误：未找到 $AGENT_BIN（media-agent）" >&2; echo "请先在开发机运行 build-server.sh，再 scp 到服务器：" >&2; echo "  scp deploy/artifacts/media-agent root@<公网IP>:/opt/myphone/media-agent" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "错误：缺少 $ENV_FILE，请先运行 install-deps.sh" >&2; exit 1; }

# ---------- 运行用户 ----------
if ! id myphone >/dev/null 2>&1; then
    useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin myphone
    echo "==> 已创建系统用户 myphone"
fi

# ---------- 安装二进制 + systemd ----------
mkdir -p "$APP_DIR"
install -m 0755 "$BIN" "$APP_DIR/myphone-server"
install -m 0644 "$SCRIPT_DIR/systemd/myphone.service" /etc/systemd/system/myphone.service

systemctl daemon-reload
systemctl enable --now myphone
systemctl restart myphone
sleep 1
echo "==> myphone 服务已启动"

# ---------- 安装 media-agent（v1.50 AI 语音媒体端点） ----------
install -m 0755 "$AGENT_BIN" "$APP_DIR/media-agent"
install -m 0644 "$SCRIPT_DIR/systemd/media-agent.service" /etc/systemd/system/media-agent.service
systemctl daemon-reload
systemctl enable --now media-agent
systemctl restart media-agent
sleep 1
echo "==> media-agent 服务已启动"

# ---------- 管理后台 Basic Auth ----------
if [ -f /etc/nginx/.myphone-htpasswd ] && [ -z "${MYPHONE_ADMIN_PASSWORD:-}" ]; then
    echo "==> 复用已有 htpasswd（如需改密，设置 MYPHONE_ADMIN_PASSWORD 后重跑）"
else
    # 用户手动指定 MYPHONE_ADMIN_PASSWORD 时强制校验强度；
    # 自动生成（openssl rand -base64 12，96 bit 熵）的一律够强，无需校验。
    if [ -n "${MYPHONE_ADMIN_PASSWORD:-}" ]; then
        PW="${MYPHONE_ADMIN_PASSWORD}"
        if [ "${#PW}" -lt 12 ] || ! [[ "$PW" =~ [^a-zA-Z0-9] ]]; then
            echo "错误：MYPHONE_ADMIN_PASSWORD 过弱（需 ≥12 字符且包含特殊字符）" >&2
            exit 1
        fi
    fi
    ADMIN_PASSWORD="${MYPHONE_ADMIN_PASSWORD:-$(openssl rand -base64 12)}"
    command -v htpasswd >/dev/null 2>&1 || { echo "错误：缺少 htpasswd（apache2-utils/httpd-tools）" >&2; exit 1; }
    htpasswd -cb /etc/nginx/.myphone-htpasswd "$ADMIN_USER" "$ADMIN_PASSWORD"
    chmod 600 /etc/nginx/.myphone-htpasswd
    echo "==> 管理后台凭据: 账号=$ADMIN_USER 密码=$ADMIN_PASSWORD"
fi

# ---------- Nginx ----------
mkdir -p /etc/nginx/conf.d
install -m 0644 "$SCRIPT_DIR/nginx/myphone-http.conf" /etc/nginx/conf.d/myphone.conf
rm -f /etc/nginx/sites-enabled/default   # 移除默认站点，避免与 conf.d 冲突
nginx -t && systemctl reload nginx
echo "==> Nginx 已加载 myphone 配置"

# ---------- 结果检查 ----------
sleep 1
systemctl is-active --quiet myphone && echo "==> myphone: active" || { echo "!! myphone 未正常运行，查看日志：journalctl -u myphone -n 50" >&2; exit 1; }
systemctl is-active --quiet media-agent && echo "==> media-agent: active" || { echo "!! media-agent 未正常运行，查看日志：journalctl -u media-agent -n 50" >&2; exit 1; }
echo "==> /health: $(curl -s http://127.0.0.1/health)"
echo "==> media-agent /health: $(curl -s http://127.0.0.1:8090/health)"
echo ""
echo "管理后台: http://<公网IP>/admin"
echo "服务端日志: journalctl -u myphone -f"
echo "媒体端点日志: journalctl -u media-agent -f"
