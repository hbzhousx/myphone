#!/usr/bin/env bash
# ============================================================
# MyPhone 生产 APK 构建脚本（在开发机上执行）
# 前置：
#   1) cp build.env.example .env.local 并填写（服务器 IP、TURN 密码等）
#   2) 已安装 Flutter SDK
# 功能：以编译期注入的生产配置打 Release APK。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.local"

# JAVA_HOME 修正：部分环境 JAVA_HOME 指向不存在的嵌套路径，导致 Gradle 失败。
# 若当前 JAVA_HOME 无效，尝试常见 JDK 路径。
if [ -n "${JAVA_HOME:-}" ] && [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "警告: JAVA_HOME=$JAVA_HOME 无效，尝试探测 JDK"
    unset JAVA_HOME
fi
if [ -z "${JAVA_HOME:-}" ]; then
    for d in /usr/lib/jvm/java-17-openjdk-amd64 /home/*/jdk17; do
        if [ -x "$d/bin/java" ]; then
            export JAVA_HOME="$d"
            break
        fi
    done
fi

[ -f "$ENV_FILE" ] || {
    echo "错误：缺少 $ENV_FILE" >&2
    echo "请先执行: cp $SCRIPT_DIR/build.env.example $ENV_FILE 并填写" >&2
    exit 1
}
set -a; source "$ENV_FILE"; set +a

: "${MYPHONE_SERVER_HOST:?未设置}"
MYPHONE_SERVER_PORT="${MYPHONE_SERVER_PORT:-80}"
MYPHONE_SERVER_TLS="${MYPHONE_SERVER_TLS:-false}"
MYPHONE_STUN_URL="${MYPHONE_STUN_URL:-stun:$MYPHONE_SERVER_HOST:3478}"
MYPHONE_TURN_URL="${MYPHONE_TURN_URL:?未设置}"
MYPHONE_TURN_USERNAME="${MYPHONE_TURN_USERNAME:-myphone}"
MYPHONE_TURN_CREDENTIAL="${MYPHONE_TURN_CREDENTIAL:?未设置}"

cd "$SCRIPT_DIR/../apps/mobile"
# 优先离线解析（依赖已在 pub 缓存，避免联网获取安全通告因网络抖动失败）
flutter pub get --offline || flutter pub get
flutter build apk --release \
    --dart-define=MYPHONE_SERVER_HOST="$MYPHONE_SERVER_HOST" \
    --dart-define=MYPHONE_SERVER_PORT="$MYPHONE_SERVER_PORT" \
    --dart-define=MYPHONE_SERVER_TLS="$MYPHONE_SERVER_TLS" \
    --dart-define=MYPHONE_STUN_URL="$MYPHONE_STUN_URL" \
    --dart-define=MYPHONE_TURN_URL="$MYPHONE_TURN_URL" \
    --dart-define=MYPHONE_TURN_USERNAME="$MYPHONE_TURN_USERNAME" \
    --dart-define=MYPHONE_TURN_CREDENTIAL="$MYPHONE_TURN_CREDENTIAL"

APK="build/app/outputs/flutter-apk/app-release.apk"
echo "============================================================"
echo " 构建完成：$(pwd)/$APK"
echo " 服务器: $MYPHONE_SERVER_HOST:$MYPHONE_SERVER_PORT (TLS=$MYPHONE_SERVER_TLS)"
echo " TURN:   $MYPHONE_TURN_URL"
echo " 分发：把 APK 发给测试用户安装即可。"
echo "============================================================"
