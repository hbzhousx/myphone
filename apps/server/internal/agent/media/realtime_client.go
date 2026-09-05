// vllm-omni Realtime 客户端适配器：直连 vllm-omni 的 OpenAI Realtime WS
// （experimental/fullduplex，MiniCPM-o 4.5 native full-duplex），绕过
// qwen-audio-agent 网关。
//
// 连接：WS /v1/realtime?duplex=1
// 事件（OpenAI Realtime 风格，字段名以服务端 realtime_output.py 为准）：
//   客户端→服务端：session.update / input_audio_buffer.append(PCM16k base64)
//   服务端→客户端：session.created / response.listen / response.audio.delta
//                 （PCM24k base64，delta 字段）/ response.audio_transcript.delta
//                 （delta 字段）/ response.audio_transcript.done（transcript 字段）
//
// 打断：native duplex 服务端 VAD 自动 barge-in（模型级，实测通过），客户端
// 不发任何打断事件；收到 response.listen 时清播放队列即可。
//
// 数据流：
//   手机 Opus → [OpusCodec.DecodeTo16k] → input_audio_buffer.append(PCM16k)
//   response.audio.delta(PCM24k) → [OpusCodec.EncodeFrom24k] → Opus → [Session.PlayFrame]
//
// 配置（env，见 RealtimeConfigFromEnv）：
//   AGENT_VLLMOMNI_URL=ws://127.0.0.1:8099/v1/realtime?duplex=1
//   AGENT_VLLMOMNI_MODEL=openbmb/MiniCPM-o-4_5（默认）
//   AGENT_VLLMOMNI_INSTRUCTIONS=<persona>（session.update instructions 透传）
//   AGENT_VLLMOMNI_REF_AUDIO=<wav 路径>（音色，data URL 透传）
//   AGENT_VLLMOMNI_DEBUG=1（dump 前 20 条服务端事件原文）
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

// RealtimeConfig 是 vllm-omni Realtime 客户端配置。独立于 env 是为了单测。
type RealtimeConfig struct {
	URL           string
	Model         string
	Instructions  string
	RefAudioPath  string
	DebugRawEvent bool
}

// RealtimeConfigFromEnv 从环境变量读取配置。
func RealtimeConfigFromEnv() RealtimeConfig {
	cfg := RealtimeConfig{
		URL:           os.Getenv("AGENT_VLLMOMNI_URL"),
		Model:         os.Getenv("AGENT_VLLMOMNI_MODEL"),
		Instructions:  os.Getenv("AGENT_VLLMOMNI_INSTRUCTIONS"),
		RefAudioPath:  os.Getenv("AGENT_VLLMOMNI_REF_AUDIO"),
		DebugRawEvent: os.Getenv("AGENT_VLLMOMNI_DEBUG") != "",
	}
	if cfg.Model == "" {
		cfg.Model = "openbmb/MiniCPM-o-4_5"
	}
	return cfg
}

const (
	upSampleRate   = 16000
	upChunkSamples = 3200 // 上行累积粒度 200ms@16k（demo 实测可用值；调小可降延迟）
)

// RealtimeClient 是连到 vllm-omni Realtime 端点的单连接客户端。
// 每个 AI 会话复用同一连接（协议按 session 组织，media-agent 单用户场景无需多会话）。
type RealtimeClient struct {
	cfg RealtimeConfig
	url string // 规整后（含 duplex query）的地址，供重连复用

	// refAudioDataURL 是 ref_audio 文件读出的 data URL（构造时读一次）。
	refAudioDataURL string

	mu   sync.Mutex
	conn *websocket.Conn

	// 上行缓冲：AppendPCM16k 逐 20ms 帧到达，累积满 upChunkSamples 再发一帧 append。
	upBuf   []int16
	upEndMs int // 累计音频时钟（audio_end_ms，服务端按累计值对齐）

	appendCount  int // 已发出的 audio.append 计数（日志用）
	eventCount   int // 已收到的事件计数（日志用）
	debugDumped  int // DEBUG 已 dump 的原文条数
	debugDropped int // audio.delta 内 audio 字段兜底命中的次数（版本漂移探针）

	// 回调（由 session/pipeline 注入）。
	// onTranscript：字幕回调。final=true 为整轮终稿（response.audio_transcript.done
	//   全文），final=false 为流式增量（response.audio_transcript.delta）。
	onTranscript  func(text string, final bool)
	onAudioDelta  func(pcm24 []int16)
	onSpeechStart func() // response.listen → 服务端 barge-in，客户端此刻清播放队列
	onVoiceReady  func()
	onError       func(err error)

	closed atomic.Bool

	// reconnecting 单飞守卫（同 GatewayClient）：初始拨号失败与 readLoop 错误
	// 都会触发重连，防止多个重连 goroutine 叠加。
	reconnecting atomic.Bool
}

// NewRealtimeClient 构造并连接 vllm-omni Realtime 端点。
func NewRealtimeClient(cfg RealtimeConfig) *RealtimeClient {
	r := &RealtimeClient{cfg: cfg}
	urlStr := cfg.URL
	if u, err := url.Parse(urlStr); err == nil {
		q := u.Query()
		if q.Get("duplex") == "" {
			q.Set("duplex", "1")
			u.RawQuery = q.Encode()
			urlStr = u.String()
		}
	}
	// 地址存字段供重连复用（gateway_client.go 根因五号：只存局部变量 →
	// 重连拨空字符串每 3s 空转）。
	r.url = urlStr
	if cfg.RefAudioPath != "" {
		if data, err := os.ReadFile(cfg.RefAudioPath); err == nil {
			r.refAudioDataURL = "data:audio/wav;base64," + base64.StdEncoding.EncodeToString(data)
			log.Printf("[VLLM] ref audio loaded: %s (%dB)", cfg.RefAudioPath, len(data))
		} else {
			log.Printf("[VLLM] ref audio read failed: %v (忽略，用服务端默认音色)", err)
		}
	}
	conn, _, err := websocket.DefaultDialer.Dial(urlStr, nil)
	if err != nil {
		log.Printf("[VLLM] connect failed: %v (retrying in background)", err)
		go r.reconnectAfterDelay()
		return r
	}
	r.conn = conn
	r.sendSessionUpdate()
	go r.readLoop(conn)
	log.Printf("[VLLM] connected to %s", urlStr)
	return r
}

// sendSessionUpdate 照抄官方 demo configure() 实测通过的形状：turn_detection
// 为 null、overlap_policy listen_only（demo 不传 turn_detection 时实发值；native
// duplex 打断是模型级的，该组合下打断实测通过）。音色/人格经 ref_audio /
// instructions 透传。
func (r *RealtimeClient) sendSessionUpdate() {
	session := map[string]interface{}{
		"model":                  r.cfg.Model,
		"modalities":             []string{"audio", "text"},
		"input_audio_format":     "pcm16",
		"output_audio_format":    "pcm16",
		"turn_detection":         nil,
		"overlap_policy":         "listen_only",
		"playback_commit_policy": "ack_only",
		"extra_body": map[string]interface{}{
			"auto_response":            true,
			"minicpmo45_native_duplex": true,
			"force_listen_count":       0,
		},
		"temperature": 0.8, // demo 实测值
	}
	if r.cfg.Instructions != "" {
		session["instructions"] = r.cfg.Instructions
	}
	if r.refAudioDataURL != "" {
		session["ref_audio"] = r.refAudioDataURL
	}
	if !r.send(map[string]interface{}{"type": "session.update", "session": session}) {
		return
	}
	log.Printf("[VLLM] session.update sent (model=%s instructions=%dB ref_audio=%v)",
		r.cfg.Model, len(r.cfg.Instructions), r.refAudioDataURL != "")
}

// AppendPCM16k 送一帧用户 PCM16k 给服务端（由 session 在 Opus→PCM16k 后调用）。
// 全速持续推流，断句/打断交给服务端 VAD（模型级 barge-in），客户端不做静音门。
func (r *RealtimeClient) AppendPCM16k(pcm []int16) {
	r.mu.Lock()
	conn := r.conn
	r.upBuf = append(r.upBuf, pcm...)
	if conn == nil || len(r.upBuf) < upChunkSamples {
		r.mu.Unlock()
		return
	}
	chunk := r.upBuf[:upChunkSamples]
	rest := r.upBuf[upChunkSamples:]
	buf := make([]byte, len(chunk)*2)
	for i, s := range chunk {
		buf[i*2] = byte(s)
		buf[i*2+1] = byte(s >> 8)
	}
	r.upBuf = append(r.upBuf[:0], rest...) // 复用底层数组，残余挪到队首
	r.upEndMs += len(chunk) * 1000 / upSampleRate
	r.mu.Unlock()

	if !r.send(map[string]interface{}{
		"type":               "input_audio_buffer.append",
		"audio":              base64.StdEncoding.EncodeToString(buf),
		"input_audio_format": "pcm16",
		"sample_rate_hz":     upSampleRate,
		"duration_ms":        upChunkSamples * 1000 / upSampleRate,
		"audio_end_ms":       r.upEndMs, // 累计媒体时钟（官方 client 同款语义）
	}) {
		return
	}
	r.appendCount++
	if r.appendCount%100 == 0 {
		log.Printf("[VLLM] sent %d audio appends (audio_end_ms=%d)", r.appendCount, r.upEndMs)
	}
}

// send 发一条 JSON 事件（mu 串行化写，conn 断开时静默丢弃并返回 false）。
func (r *RealtimeClient) send(event map[string]interface{}) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.conn == nil {
		return false
	}
	b, _ := json.Marshal(event)
	if err := r.conn.WriteMessage(websocket.TextMessage, b); err != nil {
		log.Printf("[VLLM] send failed: %v", err)
		return false
	}
	return true
}

// readLoop 读服务端事件并分发。
func (r *RealtimeClient) readLoop(conn *websocket.Conn) {
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[VLLM] read error: %v", err)
			r.mu.Lock()
			if r.conn == conn {
				r.conn = nil
			}
			r.mu.Unlock()
			if !r.closed.Load() {
				go r.reconnectAfterDelay()
			}
			return
		}
		r.dispatch(msg)
	}
}

func (r *RealtimeClient) dispatch(msg []byte) {
	var e struct {
		Type       string `json:"type"`
		Delta      string `json:"delta"`
		Audio      string `json:"audio"` // 字段兜底（OpenAI 兼容层版本差异）
		Transcript string `json:"transcript"`
		Message    string `json:"message"`
		Error      *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(msg, &e) != nil {
		return
	}
	r.eventCount++
	if r.cfg.DebugRawEvent && r.debugDumped < 20 {
		r.debugDumped++
		log.Printf("[VLLM] event #%d: %s", r.eventCount, truncateRaw(msg, 240))
	}
	switch e.Type {
	case "session.created":
		log.Printf("[VLLM] session created — downlink armed")
		if r.onVoiceReady != nil {
			r.onVoiceReady()
		}
	case "response.listen":
		// 服务端 VAD barge-in：模型开始听，客户端此刻清播放队列。
		if r.onSpeechStart != nil {
			r.onSpeechStart()
		}
	case "response.audio.delta":
		b64 := e.Delta
		if b64 == "" {
			b64 = e.Audio
			r.debugDropped++
			if r.debugDropped <= 3 {
				log.Printf("[VLLM] audio.delta carried no delta field (fell back to audio) #%d", r.debugDropped)
			}
		}
		buf, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			return
		}
		pcm := make([]int16, len(buf)/2)
		for i := range pcm {
			pcm[i] = int16(buf[i*2]) | int16(buf[i*2+1])<<8
		}
		if r.onAudioDelta != nil {
			r.onAudioDelta(pcm)
		}
	case "response.audio_transcript.delta":
		if r.onTranscript != nil {
			r.onTranscript(e.Delta, false)
		}
	case "response.audio_transcript.done":
		if r.onTranscript != nil {
			r.onTranscript(e.Transcript, true)
		}
	case "error":
		msgStr := e.Message
		if e.Error != nil && e.Error.Message != "" {
			msgStr = e.Error.Message
		}
		if r.onError != nil {
			r.onError(&realtimeError{msgStr})
		}
	default:
		// input_audio_buffer.speech_started/stopped、response.created/speak/
		// audio.done/done 等仅计数（DEBUG 时 dump），不驱动客户端行为。
	}
}

func truncateRaw(msg []byte, max int) string {
	if len(msg) > max {
		return string(msg[:max]) + "..."
	}
	return string(msg)
}

type realtimeError struct{ msg string }

func (e *realtimeError) Error() string { return "vllm-omni: " + e.msg }

// reconnectAfterDelay 3s 后重连（同 GatewayClient：本对象重拨 + 重发
// session.update，回调不换对象；失败再排程自己，直到 closed 或连上）。
func (r *RealtimeClient) reconnectAfterDelay() {
	if r.closed.Load() {
		return
	}
	if !r.reconnecting.CompareAndSwap(false, true) {
		return
	}
	defer r.reconnecting.Store(false)
	time.Sleep(3 * time.Second)
	for !r.closed.Load() {
		conn, _, err := websocket.DefaultDialer.Dial(r.url, nil)
		if err != nil {
			log.Printf("[VLLM] reconnect failed: %v (retry in 3s)", err)
			time.Sleep(3 * time.Second)
			continue
		}
		r.mu.Lock()
		if r.conn != nil {
			// 并发保护：其他路径已连上，弃用本次拨号。
			conn.Close()
			r.mu.Unlock()
			return
		}
		r.conn = conn
		r.upBuf = r.upBuf[:0]
		r.mu.Unlock()
		r.sendSessionUpdate()
		go r.readLoop(conn)
		log.Printf("[VLLM] reconnected to %s", r.url)
		return
	}
}

// SetCallbacks 注入会话回调。vllm-omni 只发 assistant 侧文本，无 role 参数。
func (r *RealtimeClient) SetCallbacks(
	onTranscript func(text string, final bool),
	onAudioDelta func(pcm24 []int16),
	onSpeechStart func(),
	onVoiceReady func(),
	onError func(err error),
) {
	r.onTranscript = onTranscript
	r.onAudioDelta = onAudioDelta
	r.onSpeechStart = onSpeechStart
	r.onVoiceReady = onVoiceReady
	r.onError = onError
}

// Close 关闭连接（残留上行缓冲一并清空）。
func (r *RealtimeClient) Close() {
	r.closed.Store(true)
	r.mu.Lock()
	if r.conn != nil {
		_ = r.conn.Close()
		r.conn = nil
	}
	r.upBuf = nil
	r.mu.Unlock()
}
