# Debug Session: mobile-crash
- **Status**: [FIXED]
- **Issue**: 手机端在启动或进入关键操作后出现闪退，需要定位根因并修复。
- **Debug Server**: http://192.168.3.113:7777/event
- **Log File**: .dbg/trae-debug-log-mobile-crash.ndjson

## Reproduction Steps
1. 在 `apps/mobile` 安装依赖并启动应用。
2. 连接后端服务后复现“手机端闪退”现象。
3. 收集启动日志、Flutter 日志和调试服务器日志。

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | 启动时本地存储/加密组件初始化失败，异常未被捕获导致应用退出 | High | Low | Pending |
| B | 登录页或路由守卫读取到空值/非法配置，构建阶段抛异常 | High | Low | Pending |
| C | Android 原生配置缺失或插件初始化失败，导致 Flutter activity 启动后崩溃 | Medium | Medium | Pending |
| D | 网络配置指向不可达服务，异步错误冒泡为未处理异常 | Medium | Low | Pending |
| E | 某个页面按钮事件触发空对象访问，在进入拨号/联系人流程时闪退 | Medium | Medium | Ruled out |
| F | 发起通话时 WebRTC 本地 SDP 构造/设置错误，导致 Flutter 层抛致命异常 | High | Medium | Confirmed |

## Log Evidence
- 当前没有设备侧回传日志；`.dbg/trae-debug-log-mobile-crash.ndjson` 尚未生成事件。
- `flutter_secure_storage` README 明确说明：Android 自动备份可能触发 `java.security.InvalidKeyException: Failed to unwrap key`。
- `local_auth` README 明确要求 Android 侧使用 `FlutterFragmentActivity`，并要求 `LaunchTheme` 继承 `Theme.AppCompat.*`。
- 本仓库修复前 Android 配置与上述要求不一致：`MainActivity` 继承 `FlutterActivity`，`LaunchTheme/NormalTheme` 使用了原生 `Theme.Light.NoTitleBar` / `Theme.Black.NoTitleBar`。
- 交互级复现已确认：`联系人 -> Alice Demo -> Audio Call` 会稳定进入通话页；首次点按只触发麦克风权限弹窗，不会闪退。
- 原始通话失败日志分两层暴露：
  - 第一层：`No enum constant org.webrtc.SessionDescription.Type.V=0`，原因是 `RTCSessionDescription` 构造参数顺序写反，把整段 SDP 当成了 `type`。
  - 第二层：修正参数顺序后，`SessionDescription is NULL`，原因是自定义 `_configureOpusSdp()` 改写后的 SDP 不再被 `flutter_webrtc` 接受。
- 最终修复方案：回到 `flutter_webrtc` 官方示例路径，直接对 `createOffer()/createAnswer()` 返回的原始 `RTCSessionDescription` 调用 `setLocalDescription()`，同时保留 `setRemoteDescription()` 的正确 `(sdp, type)` 顺序。

## Verification Conclusion
- 已加入启动阶段调试埋点，覆盖全局未捕获异常、安全存储读写、生物认证检查与鉴权。
- 已实施修复：
  - Android Activity 改为 `FlutterFragmentActivity`
  - Android 主题改为 `Theme.AppCompat.DayNight.NoActionBar`
  - `compileSdk` 提升到 35，和插件要求一致
  - 关闭 Android 自动备份，避免安全存储密钥恢复导致崩溃
  - 安全存储统一改为 `encryptedSharedPreferences + resetOnError`
  - 安全存储读取失败时对登录态降级为安全默认值，避免启动期直接闪退
  - WebRTC `RTCSessionDescription` 参数顺序修正为 `(sdp, type)`
  - 删除自定义 SDP 改写逻辑，改为直接使用 `createOffer()/createAnswer()` 的原始描述
- 已验证：
  - `flutter analyze lib/core/webrtc/webrtc_manager.dart lib/features/calls/call_state.dart` 通过
  - `flutter run -d emulator-5554` 成功启动
  - 交互级复现 `联系人 -> Alice Demo -> Audio Call` 后，应用进程保持存活，通话页停留在前台，日志中已不再出现 `Type.V=0` 或 `SessionDescription is NULL`
- 仍待后续优化：
  - `.dbg` 调试事件回传仍未打通，当前埋点 URL 写死为 `192.168.3.113:7777`，在模拟器环境下需要改成可回环地址或加回退链路
