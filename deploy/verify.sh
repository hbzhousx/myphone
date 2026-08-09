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
systemctl is-active --quiet postgresql;     check $? "PostgreSQL"
redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG; check $? "Redis"
systemctl is-active --quiet coturn;         check $? "coturn"

echo "== 2. 端口与健康 =="
[ "$(curl -s http://127.0.0.1:8080/health)" = "ok" ]; check $? "后端 /health (8080)"
[ "$(curl -s http://127.0.0.1/health)" = "ok" ];    check $? "Nginx 转发 /health (80)"
ss -ln 2>/dev/null | grep -q ':3478';                check $? "TURN 端口 3478 监听"
ss -ln 2>/dev/null | grep -q ':6379';                check $? "Redis 端口 6379 监听"

echo "== 3. 端到端 API（注册/登录）=="
PHONE="+86$(date +%s | tail -c 9)"
REG="$(curl -s -X POST http://127.0.0.1/v1/auth/register -H 'Content-Type: application/json' \
    -d "{\"phone_number\":\"$PHONE\",\"password\":\"test123\",\"identity_public_key\":\"verify\"}" || true)"
echo "$REG" | grep -q '"token"' && echo "  测试账号: $PHONE"; check $? "注册接口可用"

echo ""
echo "== 结果: $PASS 通过, $FAIL 失败 =="
[ "$FAIL" -eq 0 ]
