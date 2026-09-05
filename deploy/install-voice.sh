#!/usr/bin/env bash
# ============================================================
# MyPhone 语音链路安装脚本（demoserver 上以 sudo 执行一次）
# 安装 MiniCPM-o 全双工语音链路的两个服务：
#   llama-omni-server (GPU1, :19080)  ← 全双工推理引擎（GGUF）
#   qwen-audio-agent  (:3101, 回环)   ← 语音网关（minicpmo provider）
# 前置（开发机已完成）：
#   1) qwen-audio-agent 工作区已 rsync 到 demoserver:~/projects/qwen-audio-agent
#   2) Node 22 已装（本脚本检查版本；离线安装方式见 deploy/README.md）
#   3) npm ci && npm run build 已在 demoserver 上执行
#   4) GGUF 已 rsync 到 demoserver:~/models/MiniCPM-o-4_5/
#   5) llama-omni-server 构建产物位于
#      ~/projects/llama.cpp-omni/build-gcc11-nossl/bin/llama-omni-server
# 用法：sudo bash install-voice.sh
# ============================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "错误：请用 root 运行（sudo bash install-voice.sh）" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QWEN_DIR="/home/bear/projects/qwen-audio-agent"
OMNI_BIN="/home/bear/projects/llama.cpp-omni/build-gcc11-nossl/bin/llama-omni-server"
GGUF="/home/bear/models/MiniCPM-o-4_5/MiniCPM-o-4_5-Q4_K_M.gguf"
CFG_DIR="/etc/myphone/qwen-audio"

# ---------- 前置检查 ----------
command -v node >/dev/null 2>&1 || { echo "错误：未找到 node，请先安装 Node 22（见 deploy/README.md 语音链路一节）" >&2; exit 1; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 22 ] || { echo "错误：Node 版本过低（$(node -v)），qwen-audio-agent 要求 ≥22" >&2; exit 1; }
echo "==> Node $(node -v)"

[ -f "$QWEN_DIR/server/src/index.mjs" ] || { echo "错误：未找到 $QWEN_DIR/server/src/index.mjs（先 rsync 工作区并 npm ci && npm run build）" >&2; exit 1; }
[ -f "$OMNI_BIN" ] || { echo "错误：未找到 $OMNI_BIN（先构建 llama.cpp-omni，见 docs/voice-frontends/minicpmo.zh.md）" >&2; exit 1; }
[ -f "$GGUF" ] || { echo "错误：未找到 $GGUF（先 rsync 模型：开发机 rsync -avP ~/models/MiniCPM-o-4_5/ demoserver:~/models/MiniCPM-o-4_5/）" >&2; exit 1; }

# ---------- 配置 ----------
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config.env" <<'EOF'
# qwen-audio-agent Gateway 配置（demoserver）
# 仅回环监听：调用方只有同机 media-agent，personal 模式免 token 鉴权
HOST=127.0.0.1
PORT=3101
# 语音引擎走 minicpmo provider → llama-omni-server（GPU1）
QWEN_AUDIO_REALTIME_PROVIDER=minicpmo
MINICPMO_REALTIME_URL=ws://127.0.0.1:19080/backend
MINICPMO_MODEL=minicpmo-4.5
# 单机个人模式：/api/realtime 与 /webrtc/sdp 免鉴权（3101 不对公网开放）
QWEN_AUDIO_AGENT_IDENTITY_MODE=personal
EOF
chown -R bear:bear "$CFG_DIR"
chmod 600 "$CFG_DIR/config.env"
echo "==> 已生成 $CFG_DIR/config.env"

# ---------- systemd 单元 ----------
install -m 0644 "$SCRIPT_DIR/systemd/llama-omni-server.service" /etc/systemd/system/llama-omni-server.service
install -m 0644 "$SCRIPT_DIR/systemd/qwen-audio-agent.service"  /etc/systemd/system/qwen-audio-agent.service
systemctl daemon-reload
systemctl enable --now llama-omni-server
sleep 1
systemctl enable --now qwen-audio-agent
sleep 2

# ---------- 结果检查 ----------
systemctl is-active --quiet llama-omni-server && echo "==> llama-omni-server: active" \
    || { echo "!! llama-omni-server 未运行：journalctl -u llama-omni-server -n 50" >&2; exit 1; }
systemctl is-active --quiet qwen-audio-agent && echo "==> qwen-audio-agent: active" \
    || { echo "!! qwen-audio-agent 未运行：journalctl -u qwen-audio-agent -n 50" >&2; exit 1; }

echo "==> llama-omni-server /health: $(curl -s -m 5 http://127.0.0.1:19080/health || echo 无响应)"
echo "==> 3101 监听: $(ss -tln | grep -c ':3101' || true) 处"
echo ""
echo "语音链路已安装。验证 AI 通话看 media-agent 日志：journalctl -u media-agent -f | grep WEBRTC-UP"
echo "桌面机建议防休眠：sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
