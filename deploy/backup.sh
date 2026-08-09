#!/usr/bin/env bash
# ============================================================
# MyPhone 数据库备份脚本（服务器上执行，建议加入 crontab）
# 备份 myphone 库到 /var/backups/myphone/，保留最近 14 份。
#
# 定时任务示例（每天 03:00）：
#   0 3 * * * /root/myphone-deploy/backup.sh >> /var/backups/myphone/backup.log 2>&1
# ============================================================
set -euo pipefail

ENV_FILE="/etc/myphone/myphone.env"
[ -f "$ENV_FILE" ] || { echo "错误：缺少 $ENV_FILE" >&2; exit 1; }
source "$ENV_FILE"

BACKUP_DIR="${MYPHONE_BACKUP_DIR:-/var/backups/myphone}"
mkdir -p "$BACKUP_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
FILE="$BACKUP_DIR/db-$TS.sql.gz"

PGPASSWORD="$MYPHONE_DB_PASSWORD" pg_dump -h 127.0.0.1 -U myphone -d myphone | gzip > "$FILE"
echo "备份完成: $FILE"

# 只保留最近 14 份
ls -1t "$BACKUP_DIR"/db-*.sql.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
echo "当前备份: $(ls -1 "$BACKUP_DIR"/db-*.sql.gz 2>/dev/null | wc -l) 份"
