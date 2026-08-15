# MyPhone 聊天问题排查指南

真机聊天（收发/显示/解密）问题排查手册。覆盖历次真机 bug 的根因、诊断手段与修复。
配合服务器日志（`journalctl -u myphone -f`）与客户端诊断上报（`chatDiag`）使用。

## 核心排查链路（按症状定位）

聊天消息从「发送方输入」到「接收方显示」的完整链路，每一环都可能出问题：

```
发送方: 本地insertMessage → X3DH加密 → WS发出(sent)
服务器: 转发 chatMessage（在线直转 / 离线进Redis队列）
接收方: WS收到 → handleIncoming → 解密 → insertMessage → 聊天页_loadMessages → 渲染
```

**服务器 `[CHAT-DIAG]` 能看到的关键上报**（客户端经 `chatDiag` 上报到服务器日志）：
- `send:key-fp` — 发送方加密用的 sessionKey 指纹
- `send:ws-result` — 桥接发送是否真正发出（true/false）
- `incoming:begin / no-session / session-established / decrypted / decrypt-failed / inserted`
- `incoming:re-establish / re-established / reestablish-failed`
- `ui:loadMessages` — 聊天页 `_loadMessages` 查询的 conv/contactId/rows

**判断口诀**：
- 有 `send:key-fp` + `chatMessage` + `sent=true` → 发送链路通
- 有 `incoming:inserted` → 接收端**已入库**
- 有 `incoming:inserted` 但屏幕空白 → **显示问题**（见 §3）
- 只有 `chatMessage` 无 `incoming:*` → **接收链路没处理**（见 §5）
- `incoming:decrypt-failed` (MAC) → **X3DH 失配**（见 §4）

---

## 1. 消息发出去了但对方收不到（无报错）

**症状**：发送方显示"已发送✓"，接收方无消息。

**排查**：
1. 服务器日志有无 `type=chatMessage`？无 → 发送方 WS 没发出。
   - 常驻桥接模式（`ServiceBridgeSignalingClient`）发送是"发射后不管"，
     `CallService.sendSignal` 在服务未跑/WS 未连时**静默丢弃**。
   - 修复：`sendChatSignal` 返回真实发送结果（服务未连返回 false → 标 failed）。
2. 有 `chatMessage` 但目标在线无 `incoming:*` → 接收方没处理。
3. **user_id 错配**（重灾区）：接收方联系人/会话指向旧 user_id，发送方用新 user_id
   → 服务器按 `to_user_id` 转发，但接收方会话是旧 id → 入库到 `conv-旧id`，
   聊天页查 `conv-新id` 查不到。根治见 §6。

## 2. 发送端看不到自己的消息

**症状**：发送后聊天页空白，但会话列表有预览。

**根因**（已修复）：`getMessages` 原为 `ORDER BY created_at ASC LIMIT n`，
取的是**最旧 n 条**，新消息（created_at 最新）不在结果里 → 聊天页看不到。
**修复**：改为 `ORDER BY created_at DESC LIMIT n` 再反转（取最新 n 条）。

## 3. 消息入库了但聊天页白屏「暂无消息」

**症状**：服务器有 `incoming:inserted`，会话列表有预览，但聊天页空白。

**根因 A（已修复）**：`_loadMessages` 的 `withPaths` 循环里 `getAttachment`
对带 `transfer_id` 的附件消息查询抛异常 → 整个循环中断 → `setState` 不执行
→ `_messages` 保持空 → 白屏。
**修复**：`getAttachment` 加 try/catch，单条异常不中断刷新，`_attachment_path=null`。

**根因 B（user_id 错配）**：见 §6。

**诊断手段**：加 `ui:loadMessages` 诊断（上报 `conv/contactId/rows`）到服务器，
对比入库的 `conv`。若 `rows>0` 仍白屏 → 渲染问题；`rows=0` → 查询条件不匹配。

## 4. 接收方解密失败（MAC 认证错误）

**症状**：服务器 `incoming:decrypt-failed`，err 含
`SecretBox has wrong message authentication code (MAC)`。

**根因（已修复，identity 不同步）**：登录路径从不上传 identity → 重装/清数据后
本地生成新 identity、服务器还是旧值 → 对端取 bundle 拿旧 IK、本机用新 IK
→ X3DH DH2 不对称 → session key 不同 → 每条消息 MAC 失败。

**修复**：
- 服务器 `Register` 用 `ON CONFLICT (phone_hash) DO UPDATE SET identity_public_key`（重注册同步 identity）
- 新增 `PUT /v1/keys/identity`，客户端 `publishPrekeyBundle` 每次启动同步 identity
- `_verifyRemoteIdentity` 指纹变化时 TOFU 重新信任（不再抛 mismatch）
- 发送方每次发送重新 X3DH 协商 + 接收方解密失败时用 init_payload 强制重建会话
- 服务器 `UploadPreKeys` 先清旧再插（避免孤儿 OTP），客户端每次启动重传 OTP

**排查顺序**（对照 Signal-Android 语义）：
1. 上报 `their_ik` vs 接收方本地 `my_ik` → 不等 = identity 不同步
2. 上报 `their_spk` vs `my_spk` → 不等 = SPK 不配对
3. 缺失 OTP 私钥会报 `missing OTP private key`（响应方不再静默跳过 DH4）
4. 以上都一致仍 MAC → 消息 key 派生/加密细节（messageId/AAD/counter 两端一致性）

## 5. 接收端完全不处理入站信令

**症状**：服务器有 `chatMessage` 转发，但接收端无任何 `incoming:*` 上报。

**排查**：
1. 接收方 WS 是否在线（`client connected`）？掉线则消息进离线队列或丢弃。
2. 常驻桥接：EventChannel 订阅是否建立？`MainActivity` 的 `setEventSink` 时序。
3. `ChatStateNotifier._init` 是否卡住（`ready` 不完成 → `controllerFor` 死等，
   导致 sendText/handleIncoming 全部无响应）。`_completeReady` 兜底已修。

## 6. user_id 错配（重装/重新注册后必查）

**症状**：
- 会话列表显示一串 user_id（如 `a2531c25...`）而非联系人名字
- 消息入库到 `conv-新id`，聊天页查 `conv-旧id` → 白屏
- 重新注册后对端显示新 user_id

**根因**：手机清理数据后重新注册，服务器生成**新的 user_id**（或 ON CONFLICT
未生效），但对端联系人/会话仍指向旧 user_id。

**根治**：
1. **服务器清数据库**（users/pre_keys/signed_pre_keys/cdr），备份后 `TRUNCATE`
2. **两端手机清数据**，重新注册
3. **注册手机号格式必须完全一致**（纯数字，无 +86/空格），否则 phone_hash 不同
   → 又新建账号
4. 重新添加对方为联系人（discover 到当前 user_id）

**验证**：`ui:loadMessages` 的 `conv` 应等于入库的 `conv`；会话列表显示联系人名字。

---

## 常用命令

```bash
# 服务器日志（实时）
ssh root@47.253.158.230 'journalctl -u myphone -f | grep CHAT-DIAG'

# 查注册用户与 phone_hash 对应关系
ssh root@47.253.158.230 'PGPASSWORD=*** psql -h 127.0.0.1 -U myphone -d myphone -c \
  "SELECT id, phone_hash FROM users;"'

# 备份 + 清数据库（重装后 user_id 错配时）
ssh root@47.253.158.230 'pg_dump -h 127.0.0.1 -U myphone -d myphone > /opt/myphone/backups/pre-$(date +%s).sql'
ssh root@47.253.158.230 'psql -h 127.0.0.1 -U myphone -d myphone -c "TRUNCATE users, pre_keys, signed_pre_keys, cdr RESTART IDENTITY CASCADE;"'
```

## 客户端诊断埋点位置

- `chat_session_controller.dart`：`_reportDiag` / `reportDiagnostic`（chatDiag 上报）
- `chat_screen.dart` `_loadMessages`：`ui:loadMessages` 诊断（定位白屏）
- `chat_session_manager.dart`：identity 同步、TOFU、OTP 缺失报错
- 服务器 `hub.go`：打印 `chatDiag` 完整 payload（不转发）

> 注：`chatDiag` 是客户端上报、服务器只打印日志的诊断信令，正常收发不影响。
