# MyPhone 网络层测试方案 — 双 NAT(WiFi + 移动数据)通话无法接通

> 目标:抛开应用层,用分层实验**实证**定位"一台 WiFi 内网、一台移动数据(CGNAT)、双 NAT 下无法接通"的网络根因。
> 更新日期:2026-08-09 | 关联:`docs/e2ee-call-test-report.md`、`docs/deploy/阿里云部署手册.md`

---

## 一、结论速览(先看这里)

**✅ 最终结论(2026-08-09,两台真机跨网络实测通过):**

跨网络(不同 NAT)通话"信令通、媒体不通、无法接通"的根因已完全定位并修复,两台真机(移动数据)已能**正常接通通话**。

**根因链(三者缺一不可):**

| # | 问题 | 根因 | 修复 |
|---|------|------|------|
| 1 | 手机 UDP 受限 | 手机(尤其国内运营商)限制 App 的 **UDP 出站**,导致 TURN(UDP 3478)不可用 | **TURN over TCP**:TURN URL 加 `?transport=tcp` |
| 2 | relay 媒体不转发 | coturn 默认对 relay 端点间做 **IP 权限检查**,阻止 relay→relay 媒体数据转发 | **`server-relay`**(coturn 配置) |
| 3 | ICE 选了不通候选 | 跨 NAT 下 host/srflx 直连失败,ICE 可能选到不通路径 | **强制 `iceTransportPolicy: relay`**(App) |

**解决方案(已固化):**
1. coturn:`server-relay` + `allow-loopback-peers` + 私有段 `allowed-peer-ip`(`deploy/coturn/turnserver.conf`)
2. APK 打包:`MYPHONE_TURN_URL=turn:<IP>:3478?transport=tcp`(`deploy/build.env.example`)
3. App:`webrtc_manager.dart` 加 `iceTransportPolicy: 'relay'`

**真机验证(多场景,2026-08-09):**

| 场景 | 结果 |
|------|------|
| 两真机同 WiFi | ✅ OK |
| 一中移动数据 + 一中电信数据 | ✅ OK |
| WiFi + 移动数据(WiFi 接听) | ✅ OK |
| WiFi + 移动数据(WiFi 主叫) | ✅ OK(接续约几秒,可接受) |

- 所有跨网络场景均能接通、通话正常(有声音、双向)。
- **注意**:跨网络时接续约几秒(ICE 检查 + TURN 分配),属正常;若 App 判定超时过早可能误报"不通",实际是慢。
- 模拟器无声是**模拟器端音频设备问题**(headless 无音频输出),非 App/服务器 bug。

**排查历程**(完整记录,含被证伪的误判,见下):

排查历程(诚实记录,含一次被证伪的误判):

| # | 阶段 | 实测/发现 | 结论 |
|---|------|-----------|------|
| 1 | 服务器侦察 | STUN binding 正常;TURN 分配成功(远端移动 IP `111.183.194.1`);中继通告**公网 IP**;CreatePermission 成功 | 服务器对外基本正常 |
| 2 | 误判 | 自写 Python 双分配 relay 互发**全部失败**;coturn 日志 `peer usage: rp=0` | ❌ 一度误判为"同机 relay→relay 被封锁" |
| 3 | 深挖 | 曾假设 loopback 封锁 / 云 NAT hairpin 问题 | ❌ 均被排除 |
| 4 | **证伪** | 服务器上安装官方 `turnutils_uclient -y`(client-to-client)测试:**内网与公网路径均双向 20/20 收发、0 丢包** | ✅ **服务器 relay→relay 完全正常**;之前失败是**自写脚本设计 bug**(发送方错误地等待对端回显) |
| 5 | 跨设备复现 | 用 Android 模拟器(API 34,经 WSL2 NAT)扮演手机:**模拟器→服务器 STUN/TURN 分配 10/10 通**;但**服务器→模拟器中继端口的 relay 转发全部丢失**(uclient 10 发 0 收;自制 Go SEND 同样失败) | ⚠️ **跨公网路径的 relay 转发失败被复现**;同机 relay→relay 正常,跨设备(经公网)失败 → 与真机故障一致 |
| 6 | APK 侧确认 | 搜索 APK `libapp.so` 字节:dist 三个包均注入 `turn:47.253.158.230:3478` + 生产密码,**无**默认 `openrelay` 回退;密码与服务器、`.env.local` 三方一致 | ✅ APK TURN 注入正确,此环排除 |
| 7 | App 在模拟器运行 | myphone App 在模拟器启动,**成功连上生产 WS 信令**(`ws://47.253.158.230:80/ws`) | ✅ App 信令网络正常(仅限 TCP 80) |

**关键教训:**
1. **自写 TURN 测试脚本极易踩坑**(438 stale-nonce、FINGERPRINT/Length 语义、错误地等待对端回显、同源端口 437)。**权威判定必须用官方 `turnutils_uclient/peer`**。
2. 服务器 coturn 配置(`external-ip=公网/内网`、`relay-ip`、`listening-ip`)经验证是**正确的**,relay 通告公网 IP 可达。
3. `allow-loopback-peers` 已按早期误判添加又**回退**(它非必需且带安全警告)。
4. **跨设备 relay 转发失败被复现,且 tcpdump 定位——coturn 4.15.0 的 relay→relay 转发缺陷**:
   - 用自制 Go 双客户端(独立连接)在服务器本机做 relay→relay:无论 **SEND indication 还是 ChannelData**,无论 **relay 端口奇偶**,无论发给 **公网通告地址还是内部地址**,A 端**全部收不到**。
   - **唯一成功的是 `turnutils_uclient -y`(client-to-client)**,但 **tcpdump 证实 `-y` 的流量完全不经过中继端口(49152-65535)**,全是 `客户端 ↔ 3478 控制面` 的内部直连 → 这是 coturn 对相邻端口分配的内部优化,**不代表真实远程客户端场景**。
   - **决定性证据(rtcp_probe 独立连接 + tcpdump)**:中继端口上只有 `客户端 ↔ 3478` 的控制面流量,**中继端口之间从未出现任何数据转发**。数据从 A 的 relay socket 发出后,coturn 未投递给 B 的中继 socket。
   - 而 **relay → 普通 UDP peer 转发是正常的**(`turnutils_uclient -e ... -r <peer端口>` 10/10 通,turnutils_peer 在本机)。→ 故障**精确限定在"relay → 另一个 TURN 分配的 relay socket"这一跳**。
   - libwebrtc(真机)默认用 ChannelData 传媒体,独立连接 ChannelData 同样失败 → **真机必踩同一问题**。
   - ⚠️ 但**自制客户端测试有系统性偏差**(客户端与服务器同机、非权威),以下真机通话是更权威的复现。

5. **★真机端到端通话(2026-08-08 夜,最权威复现)——定位到 `403: Forbidden IP`**:
   - 环境:真机 `18908636668`(移动网络)拨 `13980000002`(Android 模拟器,WSL2 NAT)。
   - 信令层 **完全正常**:offer/answer/iceCandidate 全交换,来电响铃、接听成功(`answer` 信令)、E2EE 轮转(e2eeRotate)持续。
   - **媒体层失败**:coturn 日志 **`CREATE_PERMISSION processed, error 403: Forbidden IP`**(多次);同时有 success(部分 peer 允许)与 403 交替。
   - 模拟器 WebRTC 日志:ICE `gathering → complete` 用约 39 秒(异常慢),**无 `iceConnectionState` 变化(无 connected)** → 连接未建立。
   - coturn `peer usage` 全 0 → 中继媒体流量为 0。
   - **结论:通话"信令通、媒体不通",ICE 无法建立连接,且 TURN CreatePermission 被 403 拒绝是明确异常信号。** 这修正/细化了此前"纯 relay→relay 缺陷"的判断——403 拒绝 peer 导致 relay 候选不可用是更直接的机制。

**最终根因(2026-08-09 确认):** 跨网络通话"信令通、媒体不通"由三层叠加导致,缺一不可:
1. **手机 UDP 出站受限**(国内运营商/手机系统):TURN(UDP 3478)不可用,真机完全无 TURN 流量(服务器 tcpdump 证实)。
2. **coturn relay→relay 媒体不转发**:服务器上 relay 端点间数据不流转(即使 TURN 连接建立,媒体流量为 0)。
3. **ICE 可选到不通候选**:跨 NAT 下 host/srflx 直连失败。
   修复 = **`server-relay`(coturn) + TURN over TCP + 强制 `iceTransportPolicy: relay`(App)**,三者缺一不可。

**真机验证(两台真机移动数据互拨):**
- 修复后:`connectionState Connected` + `iceConnectionState Connected`,两端 TCP TURN 连接建立且有媒体数据流转(`Send-Q` 非零)。
- **通话正常接通**(有声音、双向),验证通过。
- 模拟器无声 = 模拟器端音频设备问题(headless 无音频输出),非 App/服务器 bug。

**已验证排除**:服务器认证/分配/通告、`-y` 同机 relay→relay(实为内部优化)、APK 注入、凭据一致性、RTCP 端口配对、SEND vs ChannelData、relay→普通 peer 转发、云 NAT hairpin(服务器自连公网 IP 回环 OK)。

**最终修复清单(已固化到仓库):**
1. `deploy/coturn/turnserver.conf`:`server-relay` + `allow-loopback-peers` + 私有段 `allowed-peer-ip`(解决 403 + relay 转发)。
2. `deploy/build.env.example`:`MYPHONE_TURN_URL=turn:<IP>:3478?transport=tcp`(绕过手机 UDP 限制)。
3. `apps/mobile/lib/core/webrtc/webrtc_manager.dart`:`iceTransportPolicy: 'relay'`(强制只走 TURN)。
4. 生产服务器 coturn 已应用上述配置(`server-relay` 等,健康 active)。

**经验教训补充:** 排查中最关键的两步——① 用 **GitHub 成功实践**(flutter-webrtc issue #1423/#1614)定位 `server-relay` 是 relay 转发的钥匙;② **tcpdump 抓真实流量**(而非只信日志)确认真机/模拟器是否真的连 TURN、媒体是否流转。

---

## 二、背景:网络拓扑与症状

```
  手机 A(被测:WiFi)                    手机 B(被测:移动数据)
  家宽路由器(NAT3 端口限制锥形)        运营商 CGNAT(NAT4 对称)
      │  仅 UDP 出站映射                    │  五元组绑定,端口逐目的变化
      ▼                                    ▼
   ┌─────────────────────────────────────────────┐
   │       阿里云轻量服务器 47.253.158.230        │
   │  Go 信令 :80 → :8080 │ coturn TURN :3478      │
   │  安全组:3478/udp ✓ ,49152-65535/udp ✓(已放行) │
   └─────────────────────────────────────────────┘
```

- **STUN 打洞前提是锥形 NAT**:NAT3↔NAT4、NAT4↔NAT4 在传统 STUN 下几乎无法穿透(国内 WebRTC 移动网络直连成功率实测约 15–20%)。
- **移动数据侧(中国移动)通常是对称 NAT4 + CGNAT**:同一源端口向不同目标发 UDP 会产生不同映射端口,导致打洞失效。
- **因此本场景下 TURN 中继是唯一可行媒体通道**:双端都分配 relay 候选,通过同一台 coturn 互转。
- 症状:信令正常(offer/answer/ICE 候选能交换),但媒体面建立不起来 / 接通即断 / 双向无声 → 与 relay 路径不通完全一致。

---

## 三、测试前置准备

| 项 | 说明 |
|----|------|
| 服务器 | 47.253.158.230,root SSH;改 coturn 配置需授权 |
| TURN 凭据 | `myphone` / `<install-deps.sh 生成的密码>`(存于 `deploy/.env.local`) |
| 本机(开发机) | Ubuntu 22.04 WSL2,已具备 python3 |
| 测试工具 | 见附录 A(需 `sudo apt-get install -y coturn` 获得 turnutils;你可在输入框执行 `! sudo apt-get install -y coturn`) |
| 手机侧工具 | Termux(`pkg install coturn` 提供 turnutils)或 [PureNATCheck](https://github.com/halifox/PureNATCheck)(RFC5780 NAT 检测 App) |
| 双网络路径 | 路径①=手机 A 的 WiFi;路径②=手机 B 的移动数据(可用手机 USB 网络共享给笔记本跑 turnutils) |

---

## 四、分层测试方案总览

自底向上,逐层隔离。**任何一层失败,根因即在该层或更下层**,不必继续往上。

```
L0 服务器 coturn 功能自检(已部分完成)
L1 双网络路径 → TURN 服务器可达性与分配
L2 双网络路径 NAT 类型判定
L3 STUN 打洞直连尝试
L4 TURN relay 端到端中继(★核心,已定位根因)
L5 Tailscale 独立对照实验(交叉验证拓扑能否直连)
L6 与应用桥接的最终确认
```

---

## 五、逐层测试细则

### L0 — 服务器侧 coturn 自检(★已基本完成)

目标:证明"服务器本身 + 外网可达性"这一层没问题。

- 已完成:STUN binding ✅、远端分配 ✅、中继通告公网 IP ✅、CreatePermission ✅、relay→relay ❌、hairpin ✅。
- 补充自检(在服务器或本机跑官方工具):
  ```bash
  # 服务器上(如本机已 apt install coturn 也可在本机跑):
  turnutils_peer -p 34800 &
  turnutils_uclient -v -e 47.253.158.230 -r 34800 -u myphone -w <密码> 47.253.158.230
  ```
  期望:100% 成功(0 丢包),中继地址为公网 IP。
- **L0 结论已经足够:服务器对外、认证、分配、通告全部正常;唯一异常是 relay→relay。→ 跳到 L4 确认根因。**

### L1 — 双网络路径的 TURN 可达性与分配

目标:确认 WiFi 路径与移动数据路径都能连上 coturn 并分配。

- 路径①:笔记本连手机 A 的 WiFi,跑 `turnutils_uclient`(或 relay_test 脚本)。
- 路径②:手机 B 开 USB 网络共享,笔记本走其网络跑同样命令。
- 期望:两条路径都 `ALLOC OK`,通告地址为公网 IP。
- 若某条路径分配失败:该路径 UDP 3478 被运营商阻断/劫持(移动数据偶见),或安全组未放行 3478/udp。

### L2 — 双网络路径 NAT 类型判定

目标:量化两条路径的 NAT 行为,预测打洞成功率。

- 工具:`turnutils_stunclient` / `turnutils_natdiscovery`(RFC5780)、[natcheck](https://github.com/1mb-dev/natcheck)、Tailscale `netcheck`、手机端 [PureNATCheck](https://github.com/halifox/PureNATCheck)。
- 关键指标:
  - `mapping` 行为:`endpoint-independent`(锥形,可打洞)vs `address-and-port-dependent`(对称,不可打洞)。
  - `filtering` 行为:endpoint-independent(易)vs address-dependent / address-and-port-dependent(难)。
  - UDP 是否被完全阻断(某些企业/校园 WiFi)。
- 预期:WiFi 路径 ≈ 端口限制锥形(NAT3);移动数据路径 ≈ 对称(NAT4)。→ 印证"必须走 TURN"。

### L3 — STUN 打洞直连尝试

目标:实测两条路径能否打洞直连(预期失败,用于排除 + 与 L5 交叉验证)。

- 方法 A(推荐,最小 WebRTC 页面):用浏览器/两台手机打开一个只有 `RTCPeerConnection` 的空页面,把 ICE 候选 `candidate` 字符串 + `iceConnectionState` 打出来。观察候选类型:
  - 出现 `typ srflx` 且 `typ srflx` 配对能 `connected` → 打洞成功(异常情况,需继续查)。
  - 只有 host 与 relay,`typ srflx` 配对一直 `checking`→`failed` → 打洞失败(本场景预期)。
- 方法 B:两台手机装 Tailscale,`tailscale ping <对端>` 观察 `direct` 还是 `relay`(见 L5)。
- 预期:直连失败。**这不是 bug,是拓扑的物理约束**;关键是确保回落到 TURN 时 TURN 能用(L4)。

### L4 — TURN relay 端到端中继(★核心,已定位根因)

目标:双路径各自分配 relay 后,**通过同一台 coturn 互转媒体**,这是本场景能否通话的命门。

- 工具:本仓库新增 `deploy/tools/turn_relay_test.py`(两个分配互发 + CreatePermission + 数据回显)。
- 场景:
  1. **本机双分配**(已完成):同服务器 relay→relay 双向失败 → 根因已定位。
  2. **跨双路径**:路径①笔记本跑 `turn_relay_test.py`,路径②笔记本跑一个简化对端(各分配一个 relay,互发)。用于确认修复后跨 WiFi/移动数据真实路径也通。
  3. **安全组对照实验(可选)**:临时在阿里云控制台关闭 `49152-65535/udp` 再测——确认该端口范围对 relay→relay 是否必要(不影响 3478 控制面,一般不影响同服务器互转;开/关都通才是预期)。
- 期望(修复后):双向 `OK`。
- 判定:见第 7 节矩阵。

### L5 — Tailscale 独立对照实验

目标:用完全独立的实现(Tailscale)回答"这两条路径**物理上**能否建立直连 UDP,还是只能靠中继",交叉验证 L3/L4。

**Tailscale 机制要点(调研结论):**
- 架构:控制面(协调服务器,负责发现/密钥/分配 DERP)+ 数据面(WireGuard,端到端加密)。
- 连接建立顺序:先经 DERP 中继(始终可用,TCP/TLS 443)→ 同时并行 UDP 打洞 → 成功则升级为 `direct`,失败保持 `relay`。
- 关键特性:**DERP 是默认且永远在线的兜底**(任何能开 HTTPS 的网络都能通),直连只是优化——这是它比 WebRTC 健壮的原因。
- `tailscale netcheck` 输出 `MappingVariesByDestination: true` 即对称 NAT 指示(打洞无望)。
- 对 CGNAT↔CGNAT(双向对称)场景,DERP 中继几乎是唯一出路——与我们的 TURN 处境完全同构。

**实验步骤:**
1. 两台手机装 Tailscale App,`tailscale up` 加入同一 tailnet。
2. 手机 A:`tailscale ping <手机B的100.64.x.x>`。
   - 输出 `pong via DERP(...)` → 拓扑只能中继(印证本场景必须 TURN)。
   - 输出 `pong via 公网IP:port direct` → 能打洞!则应用问题在别处(L3/L4 要复查)。
3. 手机/笔记本:`tailscale netcheck` 记录 NAT 类型。
4. 可选:自建 DERP 或观察 DERP 区域,评估中继延迟(对应 TURN 中继的路径质量)。

> 借鉴意义:即便本场景注定走中继,也建议给 App 加 **DERP 式的"永远在线兜底"**:优先尝试 srflx 打洞(快),但 TURN 候选要**从呼叫一开始就就绪**,且把 TURN 连通性作为呼叫前提之一(类似 Tailscale 先经 DERP 再升级)。避免"以为能直连,实际打洞失败后 relay 又慢/未就绪"的窗口。

### L6 — 与应用桥接的最终确认

目标:网络层证明可用后,回到 App 做最小闭环验证(可放在确认修复之后)。

- 用 App 自带诊断:`myphone_diag.log`(`/storage/emulated/0/Android/data/com.myphone.app/files/`)+ 通话界面诊断面板。
- 观察点:
  - 双端 `localCandidates` 是否包含 `relay` 类型候选,通告地址是否为公网 IP。
  - `iceConnectionState` 是否到 `connected`,`connectionState` 是否到 `connected`。
  - 若修复后仍失败,抓 `journalctl -u coturn` 对照 L0 的 `peer usage` 是否非零。

---

## 六、已执行的服务器侧验证与修正(2026-08-08)

> 本小节记录已实际执行过的服务器操作,供追溯;`allow-loopback-peers` 已添加并**回退**。

**已执行:**
1. 备份配置 `cp /etc/coturn/turnserver.conf /etc/coturn/turnserver.conf.bak.<ts>`
2. 添加 `allow-loopback-peers` 并重启 → 官方工具证明 relay→relay 本就正常 → **已回退**(`sed -i` 删除该行并重启),当前配置不含该选项
3. 修复 coturn 日志文件权限(今日轮转文件 `/var/log/turnserver_2026-08-08.log` 无法创建),`chown coturn:coturn`
4. 服务器安装 `coturn-utils`(epel),获得官方 `turnutils_uclient/peer/stunclient`(服务器之前只有 `turnserver/turnadmin`)

**官方工具权威验证结果:**
```bash
# client-to-client(relay→relay)测试 —— 内网 IP:
turnutils_uclient -y -m 2 -u myphone -w <密码> -p 3478 172.19.58.9
# → tot_send_msgs=20, tot_recv_msgs=20, 丢包 0%

# 走公网 IP(模拟外部客户端):
turnutils_uclient -y -m 2 -u myphone -w <密码> -p 3478 47.253.158.230
# → 同样 20/20, 丢包 0%
```
**两个路径均正常 → 服务器 TURN 层已彻底排除。**

**下一步(网络层,按优先级):**

1. **真机双路径 TURN 测试**(复现真机问题的关键):
   - 路径①:手机 A 连 WiFi,Termux 装 `coturn`(`pkg install coturn`),跑 `turnutils_uclient -y -u myphone -w <密码> -p 3478 47.253.158.230`
   - 路径②:手机 B 用移动数据,同命令
   - 观察:分配是否成功、relay 是否公网 IP、双向收发是否 0 丢包
2. **~~APK 生产 TURN 注入~~ → ✅ 已实测确认**:搜索 APK 内 `lib/arm64-v8a/libapp.so` 字节,`dist/` 下三个包(v0.1 / -stun / -relay)**均**注入 `turn:47.253.158.230:3478`、`stun:47.253.158.230:3478`、密码 `c6b1c519...`;**无** `openrelay`/`metered` 回退。且该密码与服务器 `/etc/coturn/turnserver.conf` 的 `user=myphone:<密码>`、`.env.local` **三方完全一致**。→ 真机若装的是这三者之一,TURN 配置与凭据均正确。
3. **真机→服务器 UDP 3478 连通性**(★当前最优先):部分大陆移动网络会阻断/降级境外 UDP。用手机 Termux `turnutils_stunclient 47.253.158.230` 或 App 诊断面板确认。**若移动数据路径连 UDP 3478 都收不到响应,即是根因**——信令走 80/tcp 可通,但媒体所需 3478/udp 被运营商丢包,导致无中继候选可用。

---

## 七、结果判定矩阵

| 现象 | 根因 | 处置 |
|------|------|------|
| 服务器官方工具 relay→relay 正常(已验证) | 服务器 TURN 层无问题 | ✅ 排除 |
| APK TURN 注入(已实测 `libapp.so` 字节) | dist 三个包均注入生产 `turn:47.253.158.230:3478`,密码与服务器一致 | ✅ 排除 |
| 真机某路径 TURN 分配失败 | 该路径 UDP 3478 不可达(运营商阻断/安全组) | 换端口/换网络复测;查安全组 |
| 真机分配成功,但两路径互转失败 | 中继端口不可达 / 应用 ICE 候选问题 | 抓 coturn `peer usage`;确认真机装的 APK 是上述三者之一 |
| **APK 未注入生产 TURN(最可疑)** | 回退到默认 `openrelay.metered.ca`,大陆连不上 | 确认 `.env.local` 与 `build-apk.sh`;重新打包安装 |
| L2 双端对称 NAT | 打洞无望,必须 TURN | 正常,靠 L4 |
| L3 srflx 直连意外成功 | 拓扑比预期简单 | 复查 App 是否错误地只用了 host/srflx |
| L5 Tailscale 显示 relay(DERP) | 与 L3/L4 印证:本拓扑只能中继 | 无需处置,继续 L4 |
| L5 Tailscale 显示 direct | 能打洞! | App 端 srflx 路径应可用;回 L3/L6 查为何 App 没用上 |
| 通话短暂建立后断/双向无声 | 中继转发半通 / 码率适配 / 防火墙 UDP 保活超时 | 抓 coturn `peer usage` + App 日志;查 Refresh 保活间隔 |

---

## 八、注意事项与已踩过的坑

1. **`stale-nonce` + 438**:coturn 开了 `stale-nonce`,自制 TURN 客户端必须实现 438(Wrong nonce)重试——本机探针第一次就栽在这。官方 `turnutils_*` 与 libwebrtc(flutter_webrtc)都内置处理,但**自制测试脚本要注意**。
2. **FINGERPRINT 与 Length 字段**:coturn 4.15 的 MESSAGE-INTEGRITY 校验要求 Length **不含 FINGERPRINT**(RFC5389 存在两种惯例)。自制客户端不带 FINGERPRINT 最稳。
3. **中继端口 49152-65535/udp**:安全组现已放行。它对"客户端→3478→同服务器互转"**不是必需**(走 3478 控制面 + 内部转发),但对"外部 peer 直接打中继端口"必需。维持放行即可。
4. **UDP 到 3478 有偶发丢包/超时**:本机多次探针出现间歇超时。测试脚本要加重试;这本身也是移动网络 UDP 质量的一个信号。
5. **coturn 日志 `Local relay addr: 172.19.58.9:port` 是正常的**——那是服务器内部 socket;客户端看到的通告地址由 `external-ip` 决定,实测为公网 IP,正确。
6. **改配置前先备份,改完 `turnserver --version` 确认选项有效**(`allow-loopback-peers` 在 4.15 有效)。
7. **真机测试时确认 APK 确实注入了生产 TURN**:检查 `deploy/.env.local` 与打包命令;若 APK 用的是默认 `openrelay.metered.ca`,大陆网络根本连不上那个公共 TURN。
8. **【重要教训】自写 TURN 测试脚本易误导,权威判定必须用官方 `turnutils_*`**:本次曾因自写 Python 双分配 relay 测试全部失败,一度误判"服务器 relay→relay 被封锁",实际是**脚本设计 bug**(发送方在 SEND 后错误地等待"自己收到对端回显",而对端从未回显;且受同源端口 437、438 stale-nonce 干扰)。服务器官方工具 `turnutils_uclient -y` 一次通过。**排查服务器时,先装官方工具做对照,再信自写脚本的结论。**

---

## 九、附录

### A. 工具清单与安装

| 工具 | 用途 | 安装 |
|------|------|------|
| `turnutils_uclient/peer/stunclient/natdiscovery` | TURN/STUN 官方测试 | Debian/Ubuntu:`sudo apt-get install -y coturn`(本机需你在输入框跑 `! sudo apt-get install -y coturn`);Android Termux:`pkg install coturn` |
| `turn_relay_test.py` / `myturn_probe.py` | 本方案自制探针(仓库 `deploy/tools/`) | 无需安装,依赖 python3 |
| Tailscale | 独立连通性/中继对照 | 手机 App / 各平台客户端 |
| [PureNATCheck](https://github.com/halifox/PureNATCheck) | 手机端 RFC5780 NAT 检测 | Android/iOS |
| [natcheck](https://github.com/1mb-dev/natcheck) | CLI NAT 诊断(Go 单文件) | 编译或下载 |

### B. 快速命令速查

```bash
# 本机 STUN/TURN 探针(单分配,查通告地址)
python3 deploy/tools/myturn_probe.py 47.253.158.230 3478 myphone <密码>

# ★权威 relay→relay 测试请用官方 turnutils(服务器上已装,路径 /usr/bin):
turnutils_uclient -y -m 2 -u myphone -w <密码> -p 3478 47.253.158.230

# 自写 relay 测试脚本有局限(见"已踩过的坑"#8),仅供单分配/查通告用
python3 deploy/tools/turn_relay_test.py 47.253.158.230 3478 myphone <密码>

# 服务器看 TURN 日志
ssh root@47.253.158.230 'journalctl -u coturn -f'

# 服务器安全组状态复核(主机防火墙应 inactive,仅云安全组)
ssh root@47.253.158.230 'systemctl is-active firewalld ufw'

# Tailscale 连通性交叉验证
tailscale ping <对端100.64.x.x>   # direct vs relay
tailscale netcheck                # NAT 类型
```

### C. 参考

- Tailscale 架构与 NAT 穿透:[Tailscale 博客 NAT 穿透改进](https://tailscale.com/blog/nat-traversal-improvements-pt-1)、[Connection types · Tailscale Docs](https://tailscale.com/docs/reference/connection-types)
- coturn loopback 默认封锁:[coturn/coturn#1644](https://github.com/coturn/coturn/issues/1644)、[CVE-2020-26262](https://ubuntu.com/security/cve-2020-26262)
- turnutils 用法:[coturn README.turnutils](https://github.com/jbg/coturn/blob/master/README.turnutils)、[turnutils_uclient(1)](https://manpages.debian.org/testing/coturn/turnutils_uclient.1.en.html)
- 国内运营商 NAT 实测:[通讯人论坛 NAT444/打洞讨论](http://www.txrjy.com/thread-1017313-1-1.html)、[V2EX NAT 话题](https://global.v2ex.co/tag/NAT)
