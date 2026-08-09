# MyPhone 部署目录

正式环境（阿里云轻量应用服务器）部署脚本与配置。详细步骤见
[`docs/deploy/阿里云部署手册.md`](../docs/deploy/阿里云部署手册.md)。

## 文件说明

| 文件 | 运行位置 | 作用 |
|------|---------|------|
| `install-deps.sh` | 服务器（root，一次性） | 安装 PostgreSQL/Redis/Nginx/coturn，生成 `/etc/myphone/myphone.env` |
| `init-db.sh` | 服务器（root，一次性） | 创建 `myphone` 数据库与角色 |
| `build-server.sh` | 开发机 | 静态交叉编译 Go 服务端 → `artifacts/myphone-server` |
| `deploy-server.sh` | 服务器（root，每次发布） | 安装二进制 + systemd + Nginx，重启服务 |
| `build-apk.sh` | 开发机 | 用生产配置打 Release APK |
| `verify.sh` | 服务器 | 部署自检（服务/健康/端到端注册登录） |
| `backup.sh` | 服务器 | pg_dump 备份（保留 14 份） |
| `restore.sh` | 服务器 | 从备份恢复数据库 |
| `.env.example` | - | 服务器环境变量格式参考（实际由 install-deps.sh 生成） |
| `build.env.example` | - | 本地打包配置模板 → 复制为 `.env.local` 填写 |
| `systemd/myphone.service` | 服务器 | systemd 单元（由 deploy-server.sh 安装） |
| `nginx/myphone-http.conf` | 服务器 | 反向代理（HTTP 80 + WS + 管理后台 Basic Auth） |
| `nginx/myphone-https.conf` | 服务器 | HTTPS 版配置（拿到域名后启用） |
| `coturn/turnserver.conf` | 服务器 | TURN 配置模板（实际由 install-deps.sh 生成） |

## 一次部署流程

```bash
# ── ① 阿里云控制台（一次性）──
#   安全组放行：22, 80, 3478/tcp+udp, 49152-65535/udp（不放 8080/5432/6379）

# ── ② 把 deploy/ 目录传到服务器（一次性）──
scp -r deploy root@<公网IP>:/root/myphone-deploy/

# ── ③ 服务器：初始化（一次性）──
ssh root@<公网IP>
cd /root/myphone-deploy
bash install-deps.sh <公网IP>   # 装依赖、生成密码，记下 TURN 密码
bash init-db.sh                 # 建库

# ── ④ 开发机：编译并上传服务端 ──
bash deploy/build-server.sh
ssh root@<公网IP> 'mkdir -p /opt/myphone'
scp deploy/artifacts/myphone-server root@<公网IP>:/opt/myphone/myphone-server

# ── ⑤ 服务器：部署服务 ──
cd /root/myphone-deploy
bash deploy-server.sh           # systemd + Nginx，记下管理后台账号密码
bash verify.sh                  # 自检

# ── ⑥ 开发机：打生产 APK ──
cp deploy/build.env.example deploy/.env.local   # 填写 IP、TURN 密码
bash deploy/build-apk.sh                        # 产物 build/app/outputs/flutter-apk/app-release.apk
```

## 升级发布

```bash
# 开发机
bash deploy/build-server.sh
scp deploy/artifacts/myphone-server root@<公网IP>:/opt/myphone/myphone-server
# 服务器
bash deploy-server.sh
```

## 安全提醒

- 阿里云安全组**只**放行 `22/80/3478` 及 TURN 中继端口，后端 8080、PG 5432、Redis 6379 一律不开。
- 管理后台 `/admin` 已由 Nginx Basic Auth 保护（部署时生成随机密码）。
- 当前无域名走 HTTP，信令明文；拿到域名后务必切换 HTTPS（见手册「HTTPS 升级」）。
