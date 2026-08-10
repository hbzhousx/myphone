# MyPhone — 系统架构与功能设计文档

> 跨平台加密通话 App (Android + iPhone)
> 调研日期: 2026-07-28

> 相关文档: [v0.4 常驻进程（后台保活 + 来电唤醒）设计](./v0.4-resident-process.md)

---

## 一、项目背景

开发一款在 Android 和 iPhone 上运行的加密通话 App，核心需求：

1. **端到端加密通话** — 通话内容服务端不可解密
2. **低带宽、高延迟通话** — 弱网环境自适应，保持语音清晰可辨识
3. **通讯录管理** — 隐私保护的通讯录同步和联系人发现
4. **指纹/生物识别登录** — 安全便捷的用户认证

---

## 二、GitHub 开源项目调研

本次调研了 3 款 GitHub 10k+ 星级的开源加密通讯/通话项目，提炼其架构精华。

### 2.1 Signal (signalapp/Signal-Android ~29k ⭐)

| 维度 | 详情 |
|------|------|
| **加密协议** | Signal Protocol: X3DH（密钥协商）+ Double Ratchet（消息密钥轮转） |
| **通话加密** | WebRTC + DTLS-SRTP，信令通过 Signal 服务器转发但无法解密 |
| **语音编码** | Opus（SILK 模式用于低带宽语音） |
| **通讯录** | 本地加密存储，号码 SHA-256 哈希后上传服务端做联系人发现（不泄露明文号码） |
| **生物识别** | Android BiometricPrompt / iOS LocalAuthentication 支持指纹/面容锁定 App |
| **可借鉴点** | 最成熟的 E2E 加密通话参考实现，Signal Protocol 已是行业标准 |

### 2.2 Jitsi Meet (jitsi/jitsi-meet ~29.5k ⭐)

| 维度 | 详情 |
|------|------|
| **架构** | SFU（Selective Forwarding Unit），Jitsi Videobridge 中继加密媒体流 |
| **加密** | Insertable Streams + Olm E2EE，服务端只看到密文 |
| **语音编码** | Opus 自适应码率（6–510 kbps），SILK 用于语音、CELT 用于音频 |
| **可借鉴点** | 成熟的 WebRTC 媒体栈，Opus 码率自适应策略，错误恢复（FEC/PLC） |

### 2.3 SimpleX Chat (simplex-chat/simplex-chat ~11k ⭐)

| 维度 | 详情 |
|------|------|
| **加密** | 抗量子加密 + Double Ratchet，每个会话独立密钥 |
| **隐私** | 无电话号码、无邮箱、无用户 ID，通过邀请链接/二维码连接 |
| **通话** | E2E 加密语音/视频通话，支持通话中切换音视频 |
| **可借鉴点** | 无标识符的隐私设计哲学，抗量子加密的前瞻性 |

### 2.4 关键借鉴

| 借鉴方向 | 来源 |
|----------|------|
| 加密协议 | Signal Protocol（X3DH + Double Ratchet） |
| 媒体传输 | Jitsi 的 WebRTC + Opus 自适应管道 |
| 隐私架构 | SimpleX 的最小化元数据设计 |
| 低带宽方案 | Opus SILK 模式（6–12 kbps）+ FEC + PLC + DTX |

---

## 三、系统架构

### 3.1 整体拓扑

```
┌────────────────────────────────────────────────────────────┐
│                      Signaling Server                       │
│  ┌───────────┐  ┌───────────┐  ┌────────────┐              │
│  │  REST API  │  │ WebSocket │  │ TURN/STUN  │              │
│  │ (用户/通讯录)│  │ (信令转发) │  │ (NAT 穿透) │              │
│  └───────────┘  └───────────┘  └────────────┘              │
│        │              │              │                       │
│   PostgreSQL       Redis        Coturn                      │
└────────────────────────────────────────────────────────────┘
         │              │              │
    ┌────┴──────────────┴──────────────┴────┐
    │              Internet                  │
    └────┬──────────────┬──────────────┬────┘
         │              │              │
    ┌────┴────┐    ┌────┴────┐   P2P Media (WebRTC + DTLS-SRTP)
    │ Android │    │  iPhone │   ════════════════════════════════
    │   App   │    │   App   │   Opus SILK 6-40kbps + FEC + PLC
    └─────────┘    └─────────┘
```

### 3.2 客户端分层架构

```
┌───────────────────────────────────────────┐
│             UI Layer (Flutter)             │
│  ┌──────────┐ ┌────────┐ ┌─────────────┐  │
│  │ 通话界面  │ │ 通讯录  │ │ 设置/登录    │  │
│  └──────────┘ └────────┘ └─────────────┘  │
├───────────────────────────────────────────┤
│        State Management (Riverpod)         │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│  │CallState │ │ContactVM │ │AuthState  │  │
│  └──────────┘ └──────────┘ └───────────┘  │
├───────────────────────────────────────────┤
│           Business Logic (Dart)            │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│  │CallEngine│ │CryptoMgr │ │ContactMgr │  │
│  │+ WebRTC  │ │+ Signal  │ │+ Sync     │  │
│  │+ Opus    │ │ Protocol │ │           │  │
│  └──────────┘ └──────────┘ └───────────┘  │
├───────────────────────────────────────────┤
│         Platform Channel / FFI             │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│  │libopus   │ │libsignal │ │Biometric  │  │
│  │(C)       │ │(Rust)    │ │Prompt     │  │
│  └──────────┘ └──────────┘ └───────────┘  │
├───────────────────────────────────────────┤
│         Storage (SQLCipher)                │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│  │消息/通话  │ │ 通讯录    │ │ KeyStore  │  │
│  │记录      │ │ 缓存     │ │ 密钥存储   │  │
│  └──────────┘ └──────────┘ └───────────┘  │
└───────────────────────────────────────────┘
```

---

## 四、技术选型

| 层次 | 选择 | 理由 |
|------|------|------|
| **跨平台框架** | Flutter 3.24 | 单代码库覆盖 Android + iOS，Dart FFI 直接调用 C 库 |
| **状态管理** | Riverpod | 编译时安全，Provider 现代替代 |
| **音频引擎** | WebRTC (flutter_webrtc) | 内置 Opus + DTLS-SRTP + Jitter Buffer + NetEQ |
| **加密协议** | X3DH + Double Ratchet | `cryptography` Dart 包实现（X25519 + Ed25519 + AES-256-GCM） |
| **本地数据库** | SQLCipher (sqflite_sqlcipher) | SQLite 的 AES-256 加密版本，Android/iOS 原生 .so |
| **安全存储** | flutter_secure_storage | Android Keystore / iOS Keychain，存储认证 Token 和 DB 密钥 |
| **信令服务** | Go + Chi + WebSocket | 高并发、低延迟，单二进制部署 |
| **服务端数据库** | PostgreSQL 14 | 用户、PreKey、CDR 话单、管理日志 |
| **服务端缓存** | Redis 7 | 会话管理、PreKey 缓存 |

### 为什么选 Flutter？

| 维度 | Flutter | React Native | 原生双平台 |
|------|---------|-------------|-----------|
| 代码复用率 | ~90% | ~70% | 0% |
| 音频性能 | Skia + FFI 直调 C 库 | JS Bridge 额外开销 | 最优 |
| 开发效率 | 高 | 中 | 低 |

---

## 五、核心功能设计

### 5.1 加密通话流程

```
主叫方 (A)                             被叫方 (B)
    │                                       │
    │── 1. 获取 B 的 PreKey (服务端) ──────│  (B 预先上传预密钥)
    │── 2. X3DH 密钥协商 ──────────────────│
    │── 3. Double Ratchet 初始化 ──────────│
    │                                       │
    │── 4. WebRTC Offer (SDP) ─────────→  │  (经信令服务器透传)
    │── 5. ICE 候选交换 ──────────────→    │
    │←── 6. WebRTC Answer ──────────────   │
    │                                       │
    │═══ 7. SRTP 媒体流 (Opus) ═══════════│  (P2P / TURN 中继)
    │      AES-128-GCM + HMAC-SHA1         │
    │                                       │
    │── 8. 挂断 → Ratchet 密钥销毁 ───────│
```

**安全边界**：信令服务器只转发加密的 SDP，无法解密通话；TURN 中继只看到 SRTP 密文。

### 5.2 低带宽自适应通话

基于 Opus SILK 模式的三级降级策略：

| 等级 | 网络条件 | 码率 | 采样率 | FEC | DTX | 帧大小 |
|------|---------|------|--------|-----|-----|--------|
| **优** | RTT < 100ms, 丢包 < 2% | 32 kbps WB | 16 kHz | Off | Off | 20ms |
| **中** | RTT 100-500ms, 丢包 2-10% | 12 kbps NB/WB | 8 kHz | On | On | 20ms |
| **差** | RTT > 500ms, 丢包 10-30% | 6 kbps SILK NB | 8 kHz | Max | On | 40ms |

**网络质量检测**：每 2 秒采样 WebRTC `getStats()` 获取 RTT、丢包率、抖动，自动切换 Opus 配置。

**辅助技术**：

| 技术 | 说明 |
|------|------|
| FEC (前向纠错) | 10-20% 冗余数据，丢包无需重传即可恢复 |
| PLC (丢包隐藏) | Opus 内置，≤30% 丢包仍可理解通话 |
| DTX (静音抑制) | 不说话时带宽节省 30-50% |
| Jitter Buffer | 自适应 50-500ms 缓冲，平滑网络抖动 |

### 5.3 通讯录设计

```
客户端 (设备端)
  ├── 本地通讯录 — SQLCipher AES-256 加密存储
  │   - 联系人 ID (uuid)
  │   - 显示名称
  │   - 公钥指纹 (安全号码)
  │   - 最后在线时间
  │
  └── 联系人发现流程:
      1. 读取手机通讯录
      2. 号码 SHA-256 哈希 (加盐: "myphone-contact-v1")
      3. 上传哈希列表到服务端
      4. 服务端做集合交集匹配
      5. 返回匹配结果 (不泄露原始号码)
      6. 用户可随时撤销同步
```

### 5.4 指纹登录

```
首次设置:
  用户注册/登录 → 生成 JWT Token
  → 存储到 Android Keystore / iOS Keychain
  → 启用生物识别

后续启动:
  App 启动 → 检测已存 Token
  → 触发指纹/面容验证
  → 成功 → 解密 Token → 自动登录
  → 失败 5 次 → 回退到密码登录
```

安全层级：
1. 生物特征模板仅存储在设备 TEE/SE 安全区域（不离开设备）
2. Token 经生物识别绑定密钥加密存储
3. Secure Storage 使用 `encryptedSharedPreferences` (Android) / Keychain (iOS)

---

## 六、服务端架构

### 6.1 API 设计

| 端点 | 方法 | 认证 | 功能 |
|------|------|------|------|
| `/health` | GET | 无 | 健康检查 |
| `/v1/auth/register` | POST | 无 | 用户注册，返回 JWT |
| `/v1/auth/login` | POST | 无 | 登录，返回 JWT |
| `/v1/keys/prekeys` | POST | JWT | 上传一次性预密钥 |
| `/v1/keys/prekeys/{userID}` | GET | JWT | 获取用户预密钥 |
| `/v1/keys/signed-prekey` | POST | JWT | 上传签名预密钥 |
| `/v1/contacts/discover` | POST | JWT | 联系人发现（哈希匹配） |
| `/ws` | WebSocket | JWT | 信令转发 (SDP/ICE/Hangup) |
| `/admin` | GET | 无* | 管理后台 SPA |
| `/admin/api/*` | GET/POST | 无* | 管理 API |

> \* 管理后台开发阶段无认证，生产环境应加 Basic Auth 或 IP 白名单

### 6.2 数据库表

| 表 | 用途 |
|----|------|
| `users` | 用户 — phone_hash, password_hash (bcrypt), identity_public_key, status |
| `pre_keys` | 一次性预密钥 — user_id, key_id, public_key, is_used |
| `signed_pre_keys` | 签名预密钥 — user_id, key_id, public_key, signature |
| `cdr` | 通话详单 — caller_id, callee_id, duration, codec, bitrate, packet_loss, rtt |
| `admin_logs` | 管理操作审计日志 |

### 6.3 WebSocket Hub

```
Hub
├── clients map[userID] → *Client
├── register / unregister channels
├── readPump: 解析 JSON → 提取 to_user_id → 转发
├── writePump: send channel → ws.WriteMessage()
└── Stats: 在线数、消息数、活跃通话数
```

---

## 七、项目管理后台

内嵌在 Go 服务中的单页应用 (`/admin`)，零额外部署：

| 模块 | 功能 |
|------|------|
| 📊 系统概览 | 用户数/在线数/活跃通话/CDR 总量/PreKey 存量/内存/协程数，5 秒自动刷新 |
| 👥 用户管理 | 搜索/分页/状态过滤、创建用户、启用/禁用、详情弹窗 |
| 🟢 实时连接 | WebSocket 在线用户表（用户 ID/连接时间/持续时长） |
| 📞 CDR 话单 | 通话详单查询（主叫/被叫/时长/编码/码率/丢包率/RTT），分页 |
| 🔑 密钥管理 | PreKey 总量/可用量/低库存告警（< 10 标红）/每用户明细 |
| ⚙️ 服务状态 | Go 版本/CPU/内存/GC 次数/协程数/运行时间 |

---

## 八、项目目录结构

```
myphone/
├── apps/
│   ├── mobile/                       # Flutter 客户端
│   │   ├── lib/
│   │   │   ├── main.dart             # 入口，ZoneGuarded 崩溃保护
│   │   │   ├── app/                  # 路由、主题、认证守卫
│   │   │   ├── features/
│   │   │   │   ├── auth/             # 生物识别登录 + 注册
│   │   │   │   ├── calls/            # 通话引擎 + 拨号 + 通话界面
│   │   │   │   └── contacts/         # 联系人发现 + 同步 + 界面
│   │   │   ├── core/
│   │   │   │   ├── crypto/           # X3DH + Double Ratchet + AES-256-GCM
│   │   │   │   ├── webrtc/           # WebRTC + Opus SILK + 网络监控
│   │   │   │   ├── network/          # HTTP API + WebSocket 信令 + 配置
│   │   │   │   └── storage/          # SQLCipher 加密数据库 + 密钥管理
│   │   │   └── shared/models/        # User, Contact, CallHistory
│   │   ├── android/                  # Android 原生工程
│   │   ├── ios/                      # iOS 原生工程
│   │   └── pubspec.yaml
│   └── server/                       # Go 信令服务器
│       ├── cmd/
│       │   ├── main.go               # 服务入口
│       │   └── ws_test/              # WebSocket 集成测试
│       ├── internal/
│       │   ├── admin/                # 管理后台 (HTML SPA + API)
│       │   ├── api/                  # JWT 认证 + PreKey 管理
│       │   ├── signaling/            # WebSocket Hub
│       │   ├── discovery/            # 隐私联系人发现
│       │   └── models/               # DB 迁移 + Redis 客户端
│       ├── e2e_test.sh               # REST API 端到端测试
│       └── go.mod
├── docs/
│   └── design.md                     # 本文档
└── README.md
```

---

## 九、验证情况

| 验证项 | 方法 | 结果 |
|--------|------|------|
| Dart 静态分析 | `dart analyze lib/` | ✅ 0 errors |
| Android APK 编译 | `flutter build apk --debug` | ✅ 125MB, 4 架构 |
| Go 编译 + vet | `go build` + `go vet` | ✅ 通过 |
| REST API 9 端点 | `e2e_test.sh` | ✅ 全部返回预期状态码 |
| WebSocket 信令 10 项 | Alice/Bob Go 双客户端 | ✅ offer/answer/ICE/hangup/ghost 全通过 |
| 管理后台 8 API | curl 逐个测试 | ✅ Dashboard/Users/Connections/CDR/Keys/ServerInfo |
| 数据库迁移 | 服务器启动自动执行 | ✅ 5 张表创建成功 |

---

## 十、开发环境

| 组件 | 版本 | 安装方式 |
|------|------|----------|
| Flutter SDK | 3.24.5 | 手动 tarball → `~/flutter` |
| Dart | 3.5.4 | 随 Flutter |
| Go | 1.22.10 | 手动 tarball → `~/go` |
| JDK | Amazon Corretto 17.0.20 | 手动 tarball → `~/jdk17` |
| Android SDK | 34 (platform) + 34.0.0 (build-tools) | cmdline-tools → `~/android-sdk` |
| PostgreSQL | 14 | apt (系统自带) |
| Redis | 7 | apt (系统自带) |
