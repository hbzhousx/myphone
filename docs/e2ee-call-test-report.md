# 端到端加密通话改造与测试报告

## 1. 架构梳理与原有短板

- `apps/mobile/lib/core/network/signaling_client.dart`
  - 原先仅透传 `offer/answer/ice`，没有 E2EE 握手和轮转控制面。
- `apps/mobile/lib/core/webrtc/webrtc_manager.dart`
  - 原先只依赖 DTLS-SRTP 传输层加密，没有把媒体帧级加密能力接入通话主链路。
- `apps/mobile/lib/features/calls/call_state.dart`
  - 原先未完整接入信令连接、远端 ICE、E2EE 协商和轮转消息。
  - 状态对象以可变方式回写 Riverpod，存在 UI 不刷新的风险。
- `apps/mobile/lib/features/calls/screens/call_screen.dart`
  - 原先 E2EE 文案不能真实反映加密状态。
- `apps/mobile/lib/core/crypto/crypto_manager.dart`
  - 原有密码学能力分散，缺少面向实时通话的密钥派生、签名校验、轮转派生与完整性保护接口。

## 2. 本次落地的核心改造

- `apps/mobile/lib/core/crypto/crypto_manager.dart`
  - 新增 `X25519/ECDH + HKDF-SHA256` 通话密钥派生。
  - 新增 `Ed25519` 控制面签名与验签。
  - 新增 `HMAC-SHA256` 完整性校验。
  - 新增媒体密钥轮转派生与指纹生成能力。
- `apps/mobile/lib/features/calls/call_e2ee_manager.dart`
  - 接入 `FrameCryptorFactory + KeyProvider`，使用 `AES-GCM` 保护音视频 RTP 帧。
  - 完成 offer/answer 阶段的身份公钥、临时公钥、签名验证、共享密钥派生。
  - 增加 TOFU 指纹校验、2 分钟定时轮转、防重放校验（`sequence/timestamp/nonce`）。
  - 进一步收紧握手约束：
    - 以长期身份公钥作为联系人指纹和主要信任锚点。
    - 同时持久化并校验远端身份公钥与控制面签名公钥，避免只校验其中一条链路。
    - 在握手签名内容中显式绑定 `call_id / role / sender_user_id / receiver_user_id`。
    - answer 侧新增 `offer_hash`，强制将 answer 绑定到当前这次 offer，降低未知密钥共享和跨会话混淆风险。
- `apps/mobile/lib/features/calls/call_state.dart`
  - 接入 `offer/answer/iceCandidate/e2eeRotate/hangup` 全链路处理。
  - 修复状态发布方式，避免连接状态、通话时长、E2EE 状态更新丢失。
- `apps/mobile/lib/core/network/server_config.dart`
  - 支持通过 `--dart-define=MYPHONE_SERVER_TLS=true` 切换 `https/wss`。
- `apps/mobile/lib/main.dart`
- `apps/mobile/lib/app/auth_guard.dart`
- `apps/mobile/lib/features/auth/biometric_auth.dart`
  - 将硬编码 debug 上报限制在 `kDebugMode`，避免生产构建继续走明文旁路。

## 3. 自动化验证结果

- 静态检查：
  - `flutter analyze lib test` 通过。
- Android 构建验证：
  - `flutter build apk --debug` 通过，产物为 `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`。
- 自动化测试：
  - `flutter test` 通过，共 5 项。
- E2EE 基元性能：
  - `flutter test --reporter expanded test/core/crypto/crypto_manager_test.dart`
  - 本地实测 `deriveRotatedMediaKey + hmacSha256` 平均耗时约 `0.371ms ~ 0.514ms`，明显低于 `100ms` 预算。

## 4. 已补充的测试覆盖

- `apps/mobile/test/core/crypto/crypto_manager_test.dart`
  - 验证双方 `deriveCallSecrets()` 派生结果一致。
  - 验证 `Ed25519` 签名校验可识别篡改负载。
  - 验证 `canonicalJson()` 对字段顺序稳定。
  - 验证握手摘要在字段顺序变化时保持稳定、在参与方绑定变化时发生变化。
  - 验证密钥轮转与完整性校验操作满足延迟预算。
- `apps/mobile/test/widget_test.dart`
  - 验证应用基础启动烟雾测试通过。

## 5. 静态安全扫描结论

- 已对应用源码执行关键字扫描，未发现 `MD5/SHA1/ECB/DES/RC4/AES-128` 等弱算法使用。
- 代码中仍可见调试上报 URL 字面量，但当前已全部受 `kDebugMode` 限制，不再进入生产路径。
- 信令层仍由服务端透传 JSON，正式环境建议启用：
  - `--dart-define=MYPHONE_SERVER_TLS=true`
  - `--dart-define=MYPHONE_SERVER_HOST=<正式域名>`

## 6. 当前限制与未完成项

- 受本会话设备环境限制，尚未完成真实双端设备上的媒体面人工联调，尤其是“接收端实时解密渲染”与复杂弱网场景下的长时稳定性实测。
- 当前环境未安装 `trivy`、`osv-scanner`、`semgrep` 等外部漏洞扫描器，因此本次“漏洞扫描验证”完成的是代码级静态检查与依赖/算法人工审计，不是外部 CVE 工具扫描报告。

## 7. 建议的下一步验收

- 在两台真实设备或一真机一模拟器上执行 10 分钟以上的双向通话验证。
- 打开 TLS 信令配置后抓包确认只剩 `wss/https` 与加密媒体流。
- 补充弱网实测：高抖动、20% 丢包、500ms RTT。
- 在具备工具的 CI/安全环境中补跑 `osv-scanner` 或 `trivy fs`。
