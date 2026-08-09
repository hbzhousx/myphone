#!/usr/bin/env bash
# ============================================================
# MyPhone 服务端构建脚本（在开发机上执行）
# 功能：静态交叉编译 Linux x86_64 二进制，输出到 deploy/artifacts/
# 用法：bash build-server.sh
# 之后把二进制传到服务器：
#   ssh root@<公网IP> 'mkdir -p /opt/myphone'
#   scp deploy/artifacts/myphone-server root@<公网IP>:/opt/myphone/myphone-server
# ============================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # 仓库根目录

# 与本机 e2e_test.sh 一致的 Go 环境
export GOROOT="${GOROOT:-$HOME/go}"
export GOPATH="${GOPATH:-$HOME/go-path}"
export PATH="$GOROOT/bin:$PATH"
command -v go >/dev/null 2>&1 || { echo "错误：未找到 go，请先安装 Go 1.22+" >&2; exit 1; }

OUT_DIR="$ROOT_DIR/deploy/artifacts"
mkdir -p "$OUT_DIR"

cd "$ROOT_DIR/apps/server"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags "-s -w" -o "$OUT_DIR/myphone-server" ./cmd/
cd - >/dev/null

echo "==> 构建完成："
ls -lh "$OUT_DIR/myphone-server"
file "$OUT_DIR/myphone-server"
echo ""
echo "==> 上传到服务器："
echo "    ssh root@<公网IP> 'mkdir -p /opt/myphone'"
echo "    scp $OUT_DIR/myphone-server root@<公网IP>:/opt/myphone/myphone-server"
