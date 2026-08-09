#!/usr/bin/env bash
# ============================================================
# MyPhone 数据库恢复脚本（服务器上执行）
# 用法：sudo bash restore.sh /var/backups/myphone/db-YYYYMMDD-HHMMSS.sql.gz
# 警告：会先删除现有 myphone 库再重建恢复！
# ============================================================
set -euo pipefail

FILE="${1:?用法: restore.sh <备份文件.sql.gz>}"
[ -f "$FILE" ] || { echo "错误：备份文件不存在: $FILE" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "错误：请用 root 运行（sudo bash restore.sh ...）" >&2; exit 1; }

source /etc/myphone/myphone.env
: "${MYPHONE_DB_PASSWORD:?环境变量缺失}"

echo "⚠ 即将删除并重建 myphone 数据库（不可逆）。输入 YES 继续："
read -r CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "已取消"; exit 1; }

PGPASSWORD="$MYPHONE_DB_PASSWORD" psql -h 127.0.0.1 -U myphone -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS myphone" \
    -c "CREATE DATABASE myphone OWNER myphone"

gunzip -c "$FILE" | PGPASSWORD="$MYPHONE_DB_PASSWORD" psql -h 127.0.0.1 -U myphone -d myphone
echo "==> 恢复完成: $FILE"
echo "==> 请重启服务端以刷新缓存：systemctl restart myphone"
