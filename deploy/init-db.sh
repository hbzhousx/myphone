#!/usr/bin/env bash
# ============================================================
# MyPhone 数据库初始化脚本（服务器上以 root 执行一次）
# 前置：已运行 install-deps.sh（生成 /etc/myphone/myphone.env）
# 表结构由 Go 服务端启动时自动迁移（db.Migrate()），本脚本只建库建用户。
# ============================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "错误：请用 root 运行（sudo bash init-db.sh）" >&2; exit 1; }

ENV_FILE="/etc/myphone/myphone.env"
[ -f "$ENV_FILE" ] || { echo "错误：缺少 $ENV_FILE，请先运行 install-deps.sh" >&2; exit 1; }
source "$ENV_FILE"

: "${MYPHONE_DB_PASSWORD:?环境变量缺失}"
DB_PASSWORD="$MYPHONE_DB_PASSWORD"

# 幂等创建角色与库
# 关键：先 SET password_encryption=scram-sha-256，确保密码以 scram 存储。
# 否则部分发行版（Alibaba Cloud Linux）默认 md5，而 pg_hba 已配 scram，会导致认证失败。
if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='myphone'\"" | grep -q 1; then
    su - postgres -c "psql -c \"SET password_encryption='scram-sha-256'; CREATE ROLE myphone LOGIN PASSWORD '${DB_PASSWORD}'\""
    echo "==> 已创建角色 myphone"
else
    # 角色已存在：重置密码为 scram，兼容旧 md5 存储
    su - postgres -c "psql -c \"SET password_encryption='scram-sha-256'; ALTER ROLE myphone PASSWORD '${DB_PASSWORD}'\""
    echo "==> 角色 myphone 已存在，已重置密码为 scram"
fi

if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='myphone'\"" | grep -q 1; then
    su - postgres -c "createdb -O myphone myphone"
    echo "==> 已创建数据库 myphone"
else
    echo "==> 数据库 myphone 已存在，跳过"
fi

# 验证 TCP 密码连接
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U myphone -d myphone -tAc "SELECT 'db-ok'" | grep -q "db-ok"
echo "==> 数据库连接验证通过"
