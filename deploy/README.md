# MyPhone 部署 runbook（生产：demoserver）

**生产环境：demoserver**（bear@59.175.112.234，SSH 端口 8006 —— 路由器 DNAT 8006→22，本机内网 IP 192.168.100.104）。
**开发环境：本机**（交叉编译 Go 服务端、打 APK、模型/数据中转）。

> 历史文档 [`docs/deploy/阿里云部署手册.md`](../docs/deploy/阿里云部署手册.md) 面向已退役的
> 阿里云部署（root@47.253.158.230），仅作参考；本 README 是当前权威 runbook。
> 阿里云系统保留运行（回滚锚点 + 旧 APK 的 OTA 跳板）。

> 本次迁移的完整计划（探查结论、分阶段步骤、回滚与风险）见
> `/home/bear/projects/aliyunserver-demoserver-plan.md`。

## 文件说明

| 文件 | 作用 | 执行位置 |
|---|---|---|
| `install-deps.sh` | 装 PG16(pgdg 清华源)/Redis/Nginx/coturn，生成 `/etc/myphone/myphone.env`（含 TURN 密码），配置 ufw | demoserver（sudo） |
| `init-db.sh` | 建 `myphone` 数据库与用户 | demoserver（sudo） |
| `build-server.sh` | 交叉编译静态二进制（全静态产物兼容 demoserver glibc 2.31）→ `deploy/artifacts/` | 本机 |
| `deploy-server.sh` | 安装 systemd 单元、htpasswd（admin Basic Auth）、nginx 反代配置 | demoserver（sudo） |
| `verify.sh` | 端到端自检：4 服务 active、health、注册链路、语音链路（2b 段） | demoserver |
| `install-voice.sh` | 安装 MiniCPM-o 语音链路：`/etc/myphone/qwen-audio/config.env` + 两个 systemd 单元 | demoserver（sudo） |
| `build-apk.sh` | 读 `.env.local` 注入 7 个 dart-define 并打 release APK | 本机 |
| `build.env.example` | `.env.local` 模板（复制为 `.env.local` 使用；`.env.local` 与 `artifacts/` 已 gitignore，不得入库） | 本机 |
| `systemd/myphone.service`、`media-agent.service` | Go 服务单元（deploy-server.sh 安装） | — |
| `systemd/llama-omni-server.service`、`qwen-audio-agent.service` | 语音链路单元（install-voice.sh 安装） | — |
| `nginx/myphone-http.conf` | Nginx:80 反代 WS + admin Basic Auth | — |
| `coturn/turnserver.conf` | coturn 配置模板（含 `server-relay` + 私有段 `allowed-peer-ip`，install-deps.sh 以它为底本） | — |
| `backup.sh` / `restore.sh` | PG 备份与恢复（`pg_dump -Fc` / `pg_restore --no-owner --role=myphone`） | demoserver |

## 一次完整部署（demoserver 从零）

前置：路由器已把 **80/tcp、3478/tcp+udp、49152-65535/udp** DNAT 到 192.168.100.104（SSH 8006→22 已有）。

```bash
# 1. 上传部署脚本
scp -r deploy/ demoserver:~/deploy/

# 2. demoserver：基础依赖 + 防火墙（ufw 先放 22 防锁死，再开 80/3478/中继段）
ssh demoserver
sudo bash ~/deploy/install-deps.sh 59.175.112.234 192.168.100.104

# 3. 初始化数据库
sudo bash ~/deploy/init-db.sh

# 4. 本机：构建并上传 Go 服务
bash deploy/build-server.sh
scp deploy/artifacts/myphone-server deploy/artifacts/media-agent demoserver:/tmp/

# 5. demoserver：安装 Go 服务（systemd 单元 + htpasswd + nginx），然后自检
sudo install -m0755 /tmp/myphone-server /tmp/media-agent /opt/myphone/
sudo bash ~/deploy/deploy-server.sh
bash ~/deploy/verify.sh   # 语音 2b 段在完成第 6 步前失败，属预期

# 6. 语音链路（MiniCPM-o，见下节）

# 7. 本机：打 APK（先回填 .env.local 的 TURN 密码，取自 demoserver
#    /etc/myphone/myphone.env 的 MYPHONE_TURN_PASSWORD）
bash deploy/build-apk.sh
```

## 语音链路（MiniCPM-o 全双工）

链路：手机 → media-agent(8090) → qwen-audio-agent Gateway(:3101, 回环) → llama-omni-server(:19080, GPU1)。

```bash
# 本机：qwen-audio-agent 先 commit（minicpmo provider 等未提交文件），再同步工作区
rsync -a --exclude node_modules --exclude .git \
  ~/projects/qwen-audio-agent/ demoserver:~/projects/qwen-audio-agent/

# 本机：同步模型（≈12GB，免下载，GGUF 已在开发机）
rsync -avP ~/models/MiniCPM-o-4_5/ demoserver:~/models/MiniCPM-o-4_5/
```

Node 22 安装（qwen-audio-agent 要求 ≥22；demoserver 出网可达时在线装，不可达时本机下载 tarball scp 过去解压到 `/usr/local`）：

```bash
# 在线：
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs
# 离线兜底：本机下载 node-v22.x-linux-x64.tar.xz → scp 到 demoserver
#   sudo tar -xJf node-v22.x-linux-x64.tar.xz -C /usr/local --strip-components=1
```

demoserver 上构建并安装：

```bash
cd ~/projects/qwen-audio-agent && npm ci && npm run build
sudo bash ~/deploy/install-voice.sh

# 桌面机防休眠（AI 通话依赖 llama-omni-server 常驻）
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

验证：`curl -s http://127.0.0.1:19080/health` 返回 `"status":"ok"`；`ss -tln | grep 3101`；
`journalctl -u media-agent -f` 首呼时出现 `[WEBRTC-UP]`；首呼后 GPU1 显存 ≈11.7GB。

## 升级发布（Go 服务）

```bash
# 本机
bash deploy/build-server.sh && scp deploy/artifacts/myphone-server deploy/artifacts/media-agent demoserver:/tmp/
# demoserver
sudo install -m0755 /tmp/myphone-server /tmp/media-agent /opt/myphone/ && sudo systemctl restart myphone media-agent
```

## 数据备份与迁移

```bash
# 备份（demoserver）
sudo -u postgres pg_dump -Fc -d myphone -f ~/myphone-$(date +%F).dump
# 恢复（目标机）
sudo -u postgres pg_restore --no-owner --role=myphone -d myphone ~/myphone-XXXX.dump && psql -c ANALYZE
```

阿里云 → demoserver 迁移（2026-08 已执行）：停写窗口内 `pg_dump -Fc` 两跳传输后恢复。

## 安全提醒

- **ufw 是唯一防线**：myphone-server 绑 0.0.0.0:8080、PG/Redis/3101/19080 均无其他防护，
  默认 deny incoming，切勿加 8080/5432/6379 的 allow 规则。
- **公网可达依赖路由器 DNAT**：映射未配好前，真机连不上是预期现象。
- admin 接口走 HTTP Basic Auth（当前无 TLS，明文传输，家庭内网环境接受）。
- coturn 三个坑（模板已处理，勿删）：`server-relay` + 私有段 `allowed-peer-ip`
  （缺了跨网通话不通）；NAT 场景 `external-ip` 必须「公网IP/内网IP」双值形式。
