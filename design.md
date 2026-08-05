# MyPhone — 系统架构与实现文档

> 端到端加密通话应用 | 更新: 2026-08-02

## 一、项目概述

MyPhone 是一款跨平台加密通话 App（Android），核心技术栈 Flutter + Go。

**核心特性：**
- 端到端加密音频通话（Signal Protocol + DTLS-SRTP）
- 低带宽自适应编码（Opus SILK 6-32 kbps, FEC, PLC, DTX）
- 隐私保护通讯录（SHA-256 哈希不可逆）
- 指纹/生物识别登录

## 二、系统架构

```
┌─────────────────────┐                     ┌─────────────────────┐
│   Flutter App A     │                     │   Flutter App B     │
│   (Android)         │                     │   (Android)         │
└──────────┬──────────┘                     └──────────┬──────────┘
           │ REST API + WebSocket                      │
           ▼                                           ▼
┌──────────────────────────────────────────────────────────────┐
│              Go 信令服务器 (:8080)                             │
│  Auth │ Keys │ Contact Discovery │ WebSocket Hub │ Admin     │
└──────────────────────────────────────────────────────────────┘
           │                         │
           ▼                         ▼
      PostgreSQL 14              Redis 7

  媒体通道 (P2P): App A ════ WebRTC + SRTP ════► App B
  NAT 穿透: STUN (Google) + TURN (Metered.ca)
```

## 三、目录结构

```
apps/
├── mobile/                              # Flutter 客户端
│   └── lib/
│       ├── main.dart                    # 入口
│       ├── app/
│       │   ├── auth_guard.dart          # JWT 存取 (SecureStorage)
│       │   ├── router.dart              # GoRouter 路由
│       │   └── theme.dart               # Material 3 主题
│       ├── core/
│       │   ├── crypto/crypto_manager.dart   # X25519+AES-256-GCM+X3DH+Ratchet
│       │   ├── network/
│       │   │   ├── api_client.dart          # REST 客户端
│       │   │   ├── server_config.dart       # 服务器地址配置
│       │   │   └── signaling_client.dart    # WebSocket 信令 (自动重连)
│       │   ├── storage/
│       │   │   ├── database.dart            # SQLCipher 加密数据库
│       │   │   └── key_manager.dart         # 数据库密钥管理
│       │   └── webrtc/
│       │       ├── webrtc_manager.dart      # WebRTC + Opus 自适应
│       │       └── network_monitor.dart     # 网络质量监测
│       ├── features/
│       │   ├── auth/                    # 登录/注册/生物识别
│       │   ├── calls/
│       │   │   ├── call_state.dart          # 通话状态机 (Riverpod)
│       │   │   ├── call_e2ee_manager.dart   # E2EE 密钥协商
│       │   │   ├── incoming_call_state.dart # 来电通知状态
│       │   │   ├── ringtone_service.dart    # 系统铃音
│       │   │   ├── screens/                 # call, dialer, incoming_call, keypad
│       │   │   └── widgets/dialer_keypad.dart
│       │   ├── contacts/                # 联系人管理与界面
│       │   └── settings/                # 设置
│       └── shared/models/               # Contact, AppUser
│
└── server/                              # Go 信令服务器
    ├── cmd/main.go                      # 入口
    └── internal/
        ├── admin/admin.go               # 管理后台
        ├── api/auth.go                  # 认证 + 用户查询 API
        ├── api/keys.go                  # PreKey 管理
        ├── discovery/discovery.go       # 联系人发现
        ├── models/db.go                 # DB 迁移 + Redis
        └── signaling/hub.go             # WebSocket Hub
```

## 四、核心设计

### 4.1 信令协议

WebSocket 长连接，JSON 消息：

```json
{"type":"offer|answer|iceCandidate|ringing|hangup|busy","call_id":"uuid","from_user_id":"uuid","to_user_id":"uuid","payload":{}}
```

**完整呼叫流程：**

```
A                               Hub                                B
│ offer ───────────────────────────────────────────────────────►  │
│ ICE candidates ──────────────────────────────────────────────►  │
│                               ringing ◄───────────────────────  │
│ answer ◄──────────────────────────────────────────────────────  │
│ ICE candidates ◄──────────────────────────────────────────────  │
│ e2eeRotate ◄═══════════ 双向 ════════════════════════════════►  │
│ hangup ──────────────────────────────────────────────────────►  │
```

### 4.2 身份与隐私

- 手机号注册 → 服务端存 `SHA256("myphone-salt:" + phoneNumber)`
- 用户 ID = 随机 16 字节 hex（与号码无关）
- JWT 30 天过期
- WebSocket 鉴权：优先 Authorization header，回退 URL `?token=` 参数
- 联系人发现：客户端哈希本地号码 → 服务端集合交集匹配 → 返回匹配但不反查

### 4.3 加密体系

```
应用层:  Signal Protocol (X3DH + Double Ratchet, X25519 + AES-256-GCM)
传输层:  DTLS-SRTP (WebRTC 标准)
编码层:  Opus SILK (6-32 kbps 自适应)
```

### 4.4 低带宽自适应

| 级别 | RTT | 丢包 | 码率 | 采样率 | FEC | DTX |
|------|-----|------|------|--------|-----|-----|
| 优 | <100ms | <2% | 32kbps | 16kHz | Off | Off |
| 中 | 100-500ms | 2-10% | 12kbps | 8kHz | On | On |
| 差 | >500ms | 10-30% | 6kbps | 8kHz | On | On |

### 4.5 ICE 服务器

```
STUN: stun.l.google.com:19302, stun1.l.google.com:19302
TURN: openrelay.metered.ca:80 / :443 (openrelayproject/openrelayproject)
```

## 五、API 端点

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| POST | `/v1/auth/register` | - | 注册 |
| POST | `/v1/auth/login` | - | 登录 |
| GET | `/v1/users/{userId}` | JWT | UUID→用户信息 |
| GET | `/v1/users/by-phone/{hash}` | JWT | phone_hash→UUID |
| POST | `/v1/contacts/discover` | JWT | 联系人发现 |
| GET | `/ws` | Query token | WebSocket 信令 |

## 六、数据库表

**PostgreSQL:**
| 表 | 关键列 |
|----|--------|
| users | id, phone_hash(UNIQUE), display_name, identity_public_key, password_hash(bcrypt) |
| pre_keys | user_id(FK), key_id, public_key, is_used |
| signed_pre_keys | user_id(PK,FK), key_id, public_key, signature |
| cdr | call_id, caller_id, callee_id, duration_secs, codec, avg_bitrate_kbps |
| admin_logs | action, detail, operator, created_at |

**SQLCipher (客户端):**
| 表 | 关键列 |
|----|--------|
| contacts | id(PK), display_name, phone_hash, is_registered |
| call_history | id(PK), contact_id(FK), direction, status, duration_seconds, started_at |
| key_store | key_type(PK), key_data(BLOB) |

## 七、调试日志

**服务端日志格式：**
```
[AUTH] Login phone="18906836668" hash=d03d9743...
[SIGNAL] recv type=offer call=uuid from=uuid to=uuid  (零丢弃: 路由正常)
[SIGNAL] drop: target uuid not connected                (对端不在线)
```

**客户端日志 (adb logcat -s flutter)：**
```
[SIGNAL] connecting to ws://host/ws?token=...
[CALL] startOutgoingCall currentUser=X toUser=Y
[CALL] _resolveToUserId: contactId=X lookupHash=Y
[WEBRTC] connectionState: connected
```

## 八、常见问题排查

| 问题 | 排查步骤 |
|------|---------|
| 登录 401 | 确认 phone hash salt=`myphone-salt:`; 确认最新 APK |
| 呼叫无响应 | 检查 `[SIGNAL] drop: target not connected` — 双方需先登录 |
| to_user_id 是号码 | `_resolveToUserId` 自动把号码哈希→API→UUID，确认 API 可达 |
| 通话界面消失 | `_hasCall` 标志防竞态，`_accept` 不再 clear incoming |
| 挂断/被挂不同步 | hangup 处理 try/catch 确保 state=null 必达 |
| 无通话记录 | `callCountProvider` + `WidgetsBindingObserver.resumed` 刷新 |
| 来电显示 UUID | `_resolveContactName`: 本地DB→服务端API→兜底 |
| 无铃音 | `flutter_ringtone_player` 播系统铃音，确认通知权限 |

## 九、开发运维

```bash
# 编译服务端
cd apps/server && go build -o server ./cmd/

# 编译客户端
cd apps/mobile && flutter build apk --debug

# 启动服务
./apps/server/server     # :8080
psql -h 127.0.0.1 -U myphone -d myphone
redis-cli ping

# 客户端日志
adb logcat -s flutter

# 环境变量
DATABASE_URL=postgres://myphone:myphone@localhost:5432/myphone?sslmode=disable
REDIS_ADDR=localhost:6379
MYPHONE_SERVER_HOST=192.168.3.113
```

**测试账号：**
| 手机号 | 密码 | 服务端显示名 |
|--------|------|------------|
| 18906836668 | test123 | 手机A-18906836668 |
| 18908636669 | test123 | 手机B-18908636669 |

## 十、当前 Bug 追踪

| # | 问题 | 状态 | 修复 |
|---|------|------|------|
| 1 | Phone hash salt 不一致 | ✅ 已修复 | 统一为 `myphone-salt:` |
| 2 | toUserId 用手机号 | ✅ 已修复 | 自动哈希→查 API→UUID |
| 3 | ICE candidates 用错 to | ✅ 已修复 | contactId 用 UUID |
| 4 | 通话界面消失 | ✅ 已修复 | `_hasCall` 标志 |
| 5 | 无通话记录 | 🔧 修复中 | `callCountProvider` |
| 6 | 来电显示 UUID | ✅ 已修复 | `_resolveContactName` |
| 7 | 铃音缺失 | ✅ 已修复 | `flutter_ringtone_player` |
| 8 | WS 断线不重连 | ✅ 已修复 | 指数退避 |
| 9 | 仅 STUN 无 TURN | ✅ 已修复 | Metered TURN |
| 10 | 接收方接通后跳回首页 | ✅ 已修复 | `_accept` 移除 clear |
| 11 | 主叫显示名称变 UUID | ✅ 已修复 | `call.contactName` |
| 12 | 挂断后对端不同步 | ✅ 已修复 | try/catch 确保 state=null |
