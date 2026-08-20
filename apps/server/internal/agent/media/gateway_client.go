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

	mu   sync.Mutex
	conn *websocket.Conn

	// 回调（由 session/pipeline 注入）。
	onTranscriptFinal func(role, content string)
	onAudioDelta      func(pcm24 []int16)
	onVoiceReady      func()
	onError           func(err error)

	appendCount int // 已发出的 audio.append 计数（日志用）
	energyCount int // PCM 能量检测计数（日志用）

	closed atomic.Bool
}

// NewGatewayClient 构造并连接 Gateway。
func NewGatewayClient(codec *OpusCodec) *GatewayClient {
	g := &GatewayClient{codec: codec}
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
	conn, _, err := websocket.DefaultDialer.Dial(urlStr, nil)
	if err != nil {
		log.Printf("[GATEWAY] connect failed: %v (retrying in background)", err)
		return g // 未连上；后续由重连恢复
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
func (g *GatewayClient) AppendPCM16k(pcm []int16) {
	if g.conn == nil {
		return
	}
	// ★能量检测：确认解码出的 PCM 非静音（否则 Gateway 收不到语音）。
	g.energyCount++
	if g.energyCount%200 == 0 {
		var sum int64
		for _, s := range pcm {
			sum += int64(s) * int64(s)
		}
		rms := 0.0
		if len(pcm) > 0 {
			rms = sqrt(float64(sum) / float64(len(pcm)))
		}
		log.Printf("[GATEWAY] PCM energy rms=%.0f (should be >100 if speech)", rms)
	}
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
}

// Interrupt 打断当前回复。
func (g *GatewayClient) Interrupt() {
	g.send(map[string]interface{}{"type": "interrupt"})
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
		if g.onTranscriptFinal != nil {
			g.onTranscriptFinal(e.Role, e.Content)
		}
	case "transcript.delta":
		if g.onTranscriptFinal != nil && e.Role == "assistant" {
			g.onTranscriptFinal(e.Role, e.Delta)
		}
	case "response.started":
		if g.onTranscriptFinal != nil {
			g.onTranscriptFinal("assistant", "[speaking]")
		}
	case "response.interrupted", "response.cancelled":
		if g.onTranscriptFinal != nil {
			g.onTranscriptFinal("assistant", "[interrupted]")
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

// reconnectAfterDelay 3s 后重连（简化：不无限退避，交由上层会话生命周期管理）。
func (g *GatewayClient) reconnectAfterDelay() {
	if g.closed.Load() {
		return
	}
	time.Sleep(3 * time.Second)
	g.mu.Lock()
	if g.conn != nil {
		g.mu.Unlock()
		return
	}
	g.mu.Unlock()
	nc := NewGatewayClient(g.codec)
	g.mu.Lock()
	if g.conn == nil && nc.conn != nil {
		g.conn = nc.conn
	}
	g.mu.Unlock()
}

// SetCallbacks 注入会话回调。
func (g *GatewayClient) SetCallbacks(
	onTranscriptFinal func(role, content string),
	onAudioDelta func(pcm24 []int16),
	onVoiceReady func(),
	onError func(err error),
) {
	g.onTranscriptFinal = onTranscriptFinal
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
