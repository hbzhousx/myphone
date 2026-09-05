// Gateway 客户端适配器：把 qwen-audio-agent Gateway 当作「语音引擎」接入。
//
// 连接：WS /api/realtime?sessionId=<ownerId>（qwen-audio-agent personal 模式免鉴权）。
// 事件（契约 v2.0.0，见 qwen-audio-agent docs/contract.zh.md）：
//   客户端→服务端：connect / audio.append(PCM16k base64) / interrupt
//   服务端→客户端：voice.ready / audio.delta(PCM24k base64) / transcript.final /
//                 response.* / task.*
//
// 数据流：
//   手机 Opus → [OpusCodec.DecodeTo16k] → audio.append(PCM16k)
//   audio.delta(PCM24k) → [OpusCodec.EncodeFrom24k] → Opus → [Session.PlayFrame]
//   transcript.final → [Session.SendTranscript]（字幕）
//
// 配置（env）：
//   AGENT_GATEWAY_URL=ws://127.0.0.1:3101/api/realtime（默认）
//   AGENT_GATEWAY_SESSION_ID=<ownerId>（默认 user_personal）
package media

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/url"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// GatewayClient 是连到 qwen-audio-agent Gateway 的单连接客户端。
// 每个 AI 会话复用同一个 Gateway 连接（Gateway 按 sessionId 区分 owner）。
type GatewayClient struct {
	codec *OpusCodec

	// bypass 是 DashScope 启动旁路（联调诊断用，配置 AGENT_DASHSCOPE_KEY 时启用）。
	bypass *DashScopeBypass

	// url 是 Gateway WS 地址（含 sessionId query），供重连复用。
	url string

	mu   sync.Mutex
	conn *websocket.Conn

	// 回调（由 session/pipeline 注入）。
	// onTranscript：字幕回调（★2026-09-03 官方语义）。final=true 为整轮终稿
	//   （fork response.done 全文），final=false 为流式增量（kind:text delta）。
	onTranscript func(role, content string, final bool)
	onAudioDelta      func(pcm24 []int16)
	onVoiceReady      func()
	onError           func(err error)

	appendCount int // 已发出的 audio.append 计数（日志用）
	energyCount int // PCM 能量检测计数（日志用）

	closed atomic.Bool

	// reconnecting 单飞守卫：初始拨号失败与 readLoop 错误都会触发重连，
	//   防止多个重连 goroutine 叠加（叠加会双拨号、二 conn 覆盖一 conn）。
	reconnecting atomic.Bool
}

// NewGatewayClient 构造并连接 Gateway。
func NewGatewayClient(codec *OpusCodec) *GatewayClient {
	g := &GatewayClient{codec: codec, bypass: NewDashScopeBypass()}
	urlStr := os.Getenv("AGENT_GATEWAY_URL")
	if urlStr == "" {
		urlStr = "ws://127.0.0.1:3101/api/realtime"
	}
	u, err := url.Parse(urlStr)
	if err == nil {
		q := u.Query()
		if q.Get("sessionId") == "" {
			q.Set("sessionId", os.Getenv("AGENT_GATEWAY_SESSION_ID"))
		}
		if q.Get("sessionId") == "" {
			q.Set("sessionId", "user_personal")
		}
		u.RawQuery = q.Encode()
		urlStr = u.String()
	}
	// ★修复（2026-08-30 根因五号）：urlStr 只存在于局部变量，结构体字段 url
	//   恒为空——首次拨号成功后一旦掉线（如 19:51:19 重启 qwen-audio-agent），
	//   reconnectAfterDelay 拨空字符串 → "malformed ws or wss URL" 每 3s 空转，
	//   网关侧再无本客户端连接，真机通话音频静默丢弃（探针直连网关故不受影响）。
	g.url = urlStr
	conn, _, err := websocket.DefaultDialer.Dial(urlStr, nil)
	if err != nil {
		log.Printf("[GATEWAY] connect failed: %v (retrying in background)", err)
		// ★修复（2026-08-30）：初始拨号失败后 readLoop 从未启动，无人再触发
		//   重连——"retrying in background" 名不副实，客户端永久死亡，
		//   通话音频在 AppendPCM16k 的 conn==nil 处静默丢弃。这里真正起后台重试。
		go g.reconnectAfterDelay()
		return g
	}
	g.conn = conn
	g.sendConnect()
	go g.readLoop(conn)
	log.Printf("[GATEWAY] connected to %s", urlStr)
	return g
}

func (g *GatewayClient) sendConnect() {
	g.send(map[string]interface{}{
		"type":          "connect",
		"clientType":    "web",
		"clientLabel":   "myphone-media-agent",
		"inputEnabled":  true,
		"outputEnabled": true,
		"textOnly":      false,
	})
	// ★不在 connect 后立即 unmute：Gateway 需先 ensureFrontend（建立 DashScope 会话）
	//   才接受 unmute 激活。等 voice.ready 事件到达再发 unmute（见 dispatch）。
	//   参照 qwen-audio-agent Web 客户端：connect → 等 voice.ready → enableMicrophone 发 unmute。
}

// AppendPCM16k 送一帧用户 PCM16k 给 Gateway（由 session 在 Opus→PCM16k 后调用）。
// ★route 3：全速持续推流，断句交给网关 VAD（见函数内根因六号注释）。
func (g *GatewayClient) AppendPCM16k(pcm []int16) {
	if g.conn == nil {
		return
	}
	// 计算本帧 RMS（每帧都算，用于静音检测）。
	var sum int64
	for _, s := range pcm {
		sum += int64(s) * int64(s)
	}
	rms := 0.0
	if len(pcm) > 0 {
		rms = sqrt(float64(sum) / float64(len(pcm)))
	}
	// ★能量检测：确认解码出的 PCM 非静音（否则 Gateway 收不到语音）。
	g.energyCount++
	if g.energyCount%200 == 0 {
		log.Printf("[GATEWAY] PCM energy rms=%.0f (should be >100 if speech)", rms)
	}

	// ★修复（2026-08-30 根因六号）：turn_based（route 3）下断句完全由网关
	//   VAD 承担（800ms 静音收句按"采样数"计），这里必须全速持续推流真实
	//   音频。原静音门（full_duplex 时代化石：让模型采样循环感知停顿进入
	//   <|speak|>）在 turn_based 下三重杀伤：①静音 800ms 即弃真实音频 →
	//   句子被拦腰切碎（真机实测用户发言只剩 1-2s 碎片，轻声段整段丢失）；
	//   ②静音态降频馈送 → 网关 800ms 收句计数被拉长到 ~4s 墙钟，每句延迟
	//   5-15s 才提交；③碎片+混叠音频喂给模型 → 对每段碎片回通用问候
	//   （真机表现为"AI 听不懂我说话"）。
	sendAudioFeed(g, pcm)
}

// sendAudioFeed 把一帧 PCM16k 发到 Gateway（含 DashScope 直连旁路）。
func sendAudioFeed(g *GatewayClient, pcm []int16) {
	// int16 → []byte（LE）。
	buf := make([]byte, len(pcm)*2)
	for i, s := range pcm {
		buf[i*2] = byte(s)
		buf[i*2+1] = byte(s >> 8)
	}
	// ★日志：确认 audio.append 真的发到 Gateway（conn 断了会被 send 静默丢）。
	if g.send(map[string]interface{}{
		"type":  "audio.append",
		"audio": base64.StdEncoding.EncodeToString(buf),
	}) {
		g.appendCount++
		if g.appendCount%100 == 0 {
			log.Printf("[GATEWAY] sent %d audio.append", g.appendCount)
		}
	}
	// ★DashScope 直连旁路：同一段 PCM 同时发 DashScope，验证手机语音是否有效。
	if g.bypass != nil {
		g.bypass.AppendPCM16k(pcm)
	}
}

// Interrupt 打断当前回复。
func (g *GatewayClient) Interrupt() {
	g.send(map[string]interface{}{"type": "interrupt"})
}

// Activate 通话开始时重新主张输入所有权（unmute takeover）。
// ★2026-09-03 修复（真机"哪吒无回应"）：unmute 只在 voice.ready 发一次的
//   设计太脆——任何 takeover（联调探针/网页端接入）都会夺走输入权，且网关
//   backend 随 owner 断开而关闭（realtime.closed）。此后 media-agent 连接虽
//   在、audio.append 照发，但输入已被停用，音频全部沉入网关，通话彻底无响应
//   （20:25 通话实测 4700+ audio.append 网关零反应）。每次通话开始重新
//   takeover，网关即以本连接为 owner 重建 backend（实测 ~3.6s 连上）。
func (g *GatewayClient) Activate() {
	g.send(map[string]interface{}{"type": "unmute", "takeover": true})
}

func (g *GatewayClient) send(event map[string]interface{}) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.conn == nil {
		return false
	}
	b, _ := json.Marshal(event)
	if err := g.conn.WriteMessage(websocket.TextMessage, b); err != nil {
		log.Printf("[GATEWAY] send failed: %v", err)
		return false
	}
	return true
}

// readLoop 读 Gateway 事件并分发。
func (g *GatewayClient) readLoop(conn *websocket.Conn) {
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[GATEWAY] read error: %v", err)
			g.mu.Lock()
			if g.conn == conn {
				g.conn = nil
			}
			g.mu.Unlock()
			if !g.closed.Load() {
				go g.reconnectAfterDelay()
			}
			return
		}
		var event struct {
			Type       string `json:"type"`
			Audio      string `json:"audio"`
			SampleRate int    `json:"sampleRate"`
			Role       string `json:"role"`
			Content    string `json:"content"`
			Delta      string `json:"delta"`
			State      string `json:"state"`
			Message    string `json:"message"`
		}
		if json.Unmarshal(msg, &event) != nil {
			continue
		}
		g.dispatch(event)
	}
}

func (g *GatewayClient) dispatch(e struct {
	Type       string `json:"type"`
	Audio      string `json:"audio"`
	SampleRate int    `json:"sampleRate"`
	Role       string `json:"role"`
	Content    string `json:"content"`
	Delta      string `json:"delta"`
	State      string `json:"state"`
	Message    string `json:"message"`
}) {
	switch e.Type {
	case "voice.ready":
		// Gateway 已就绪（DashScope 会话建立）→ 此时才激活音频输入。
		// 必须带 takeover:true（旧连接若占 owner 会被 activate 拒绝）。
		log.Printf("[GATEWAY] voice.ready received — activating audio input")
		g.send(map[string]interface{}{"type": "unmute", "takeover": true})
		if g.onVoiceReady != nil {
			g.onVoiceReady()
		}
	case "audio.delta":
		// PCM base64 → int16。sampleRate 应=24000。
		buf, err := base64.StdEncoding.DecodeString(e.Audio)
		if err != nil {
			return
		}
		pcm := make([]int16, len(buf)/2)
		for i := range pcm {
			pcm[i] = int16(buf[i*2]) | int16(buf[i*2+1])<<8
		}
		if g.onAudioDelta != nil {
			g.onAudioDelta(pcm)
		}
	case "transcript.final":
		// ★2026-09-03 字幕修复：final 与 delta 统一读 e.Content（网关
		//   emitAssistantTranscript 发的是 content 字段；原 delta 读 e.Delta
		//   恒为空 → 手机端 text.isEmpty 全丢弃，字幕全无）。
		if g.onTranscript != nil {
			g.onTranscript(e.Role, e.Content, true)
		}
	case "transcript.delta":
		// 官方语义：客户端逐 delta 更新字幕（minicpmo45.modelbest.cn
		// /docs/zh/realtime-api/audio/）。final=false 增量，不触发聊天回流。
		if g.onTranscript != nil && e.Role == "assistant" {
			g.onTranscript(e.Role, e.Content, false)
		}
	case "voice.connection":
		// state: connected / unavailable / ...
	case "error":
		if g.onError != nil {
			g.onError(parseGatewayErr(e.Message))
		}
	}
}

func sqrt(x float64) float64 {
	// 简单牛顿法平方根（避免引入 math 依赖）。
	if x <= 0 {
		return 0
	}
	g := x / 2
	for i := 0; i < 20; i++ {
		if g <= 0 {
			return 0
		}
		g = (g + x/g) / 2
	}
	return g
}

func parseGatewayErr(msg string) error {
	if msg == "" {
		return nil
	}
	return &gatewayError{msg}
}

type gatewayError struct{ msg string }

func (e *gatewayError) Error() string { return "gateway: " + e.msg }

// reconnectAfterDelay 3s 后重连。★修复（2026-08-30）：原实现重连时
//   nc := NewGatewayClient 造新对象，readLoop 跑在新对象上，事件派发到旧
//   对象注入的回调 → 事件孤岛。现改为本对象重拨 + 握手，回调不换对象。
//   失败再排程自己，直到 closed 或连上。
func (g *GatewayClient) reconnectAfterDelay() {
	if g.closed.Load() {
		return
	}
	// 单飞守卫：初始失败与 readLoop 错误都可能触发重连。
	if !g.reconnecting.CompareAndSwap(false, true) {
		return
	}
	defer g.reconnecting.Store(false)
	time.Sleep(3 * time.Second)
	for !g.closed.Load() {
		conn, _, err := websocket.DefaultDialer.Dial(g.url, nil)
		if err != nil {
			log.Printf("[GATEWAY] reconnect failed: %v (retry in 3s)", err)
			time.Sleep(3 * time.Second)
			continue
		}
		g.mu.Lock()
		if g.conn != nil {
			// 并发保护：其他路径已连上，弃用本次拨号。
			conn.Close()
			g.mu.Unlock()
			return
		}
		g.conn = conn
		g.mu.Unlock()
		g.sendConnect()
		go g.readLoop(conn)
		log.Printf("[GATEWAY] reconnected to %s", g.url)
		return
	}
}

// SetCallbacks 注入会话回调。
func (g *GatewayClient) SetCallbacks(
	onTranscript func(role, content string, final bool),
	onAudioDelta func(pcm24 []int16),
	onVoiceReady func(),
	onError func(err error),
) {
	g.onTranscript = onTranscript
	g.onAudioDelta = onAudioDelta
	g.onVoiceReady = onVoiceReady
	g.onError = onError
}

// Close 关闭连接。
func (g *GatewayClient) Close() {
	g.closed.Store(true)
	g.mu.Lock()
	if g.conn != nil {
		_ = g.conn.Close()
		g.conn = nil
	}
	g.mu.Unlock()
}
