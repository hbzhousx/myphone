#!/usr/bin/env bash
# ============================================================
# MyPhone 部署自检脚本（服务器上执行）
# 检查：系统服务 / 健康检查 / 端到端注册登录
# 用法：bash verify.sh
# ============================================================
set -uo pipefail

PASS=0; FAIL=0
check() {
    if [ "$1" -eq 0 ]; then echo "  ✓ $2"; PASS=$((PASS+1)); else echo "  ✗ $2"; FAIL=$((FAIL+1)); fi
}

echo "== 1. 系统服务 =="
systemctl is-active --quiet myphone;        check $? "myphone 服务"
systemctl is-active --quiet media-agent;    check $? "media-agent 服务"
systemctl is-active --quiet postgresql;     check $? "PostgreSQL"
redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG; check $? "Redis"
systemctl is-active --quiet coturn;         check $? "coturn"

echo "== 2. 端口与健康 =="
[ "$(curl -s http://127.0.0.1:8080/health)" = "ok" ];       check $? "后端 /health (8080)"
[ "$(curl -s http://127.0.0.1:8090/health)" = "ok" ];       check $? "media-agent /health (8090)"
[ "$(curl -s http://127.0.0.1/health)" = "ok" ];    check $? "Nginx 转发 /health (80)"
# ss 一次性捕获后用 grep -c 统计：-q 匹配即退出会让 ss 收到 SIGPIPE，
# 配合 set -o pipefail 把监听正常的端口误判为失败（coturn 每核一个 UDP socket，输出量大）
SS_LISTEN="$(ss -ln 2>/dev/null || true)"
grep -c ':3478' <<<"$SS_LISTEN" >/dev/null;          check $? "TURN 端口 3478 监听"
grep -c ':6379' <<<"$SS_LISTEN" >/dev/null;          check $? "Redis 端口 6379 监听"

echo "== 2b. 语音链路（MiniCPM-o，demoserver 本地） =="
systemctl is-active --quiet llama-omni-server; check $? "llama-omni-server 服务"
grep -c ':3101' <<<"$SS_LISTEN" >/dev/null;          check $? "qwen gateway 端口 3101 监听"
HEALTH_19080="$(curl -s -m 5 http://127.0.0.1:19080/health || true)"
echo "$HEALTH_19080" | grep -q '"status":"ok"';      check $? "llama-omni-server /health (19080)"

echo "== 3. 端到端 API（自注册已停用：管理员开户制）=="
# 注册端点应返回明确的停用提示（证明 nginx→server 链路；auth.go 已禁止自助注册）
REG="$(curl -s -X POST http://127.0.0.1/v1/auth/register -H 'Content-Type: application/json' -d '{}' || true)"
echo "$REG" | grep -q 'self-registration disabled';  check $? "注册端点返回停用提示"
# 登录端点先查 users 表再校验密码：无效凭据返回 401（证明 server→PG 链路）
LOGIN_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1/v1/auth/login \
    -H 'Content-Type: application/json' -d '{"phone_number":"+8610000000000","password":"x"}' || true)"
[ "$LOGIN_CODE" = "401" ];                           check $? "登录端点查库(401=server→PG链路通)"

echo ""
echo "== 结果: $PASS 通过, $FAIL 失败 =="
[ "$FAIL" -eq 0 ]
