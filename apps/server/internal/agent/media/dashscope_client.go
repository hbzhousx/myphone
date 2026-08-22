// DashScope Realtime 直连客户端（方向 B：绕开 qwen-audio-agent Gateway）。
//
// 旁路诊断已验证：手机 PCM16k 直连 DashScope 能被识别（speech_started）。
// 本文件是完整直连：识别文本 → 字幕/聊天回流；回复音频 delta → Opus → PlayFrame 回手机。
//
// 配置：AGENT_DASHSCOPE_KEY=<key> 时启用；AGENT_DASHSCOPE_MODEL 指定模型。
package media

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// DashScopeClient 是 DashScope Realtime 直连客户端。
// 复用旁路的连接与识别,补全回复音频/文本处理。
type DashScopeClient struct {
	key     string
	model   string
	codec   *OpusCodec
	play    func(frame []byte)     // 回手机(Opus 帧)
	sendMsg func(who, text string) // 字幕（who: 'user'|'agent'）
	speech  func(speaking bool)    // 用户说话状态（麦克风动态图标）
	chatMsg func(text string)      // 聊天历史回流

	mu     sync.Mutex
	conn   *websocket.Conn
	ready  bool
	closed bool // 进程退出标记，禁止重连

	interrupted bool // 打断标记:用户插话后丢弃旧回复的 audio.delta,直到新回复开始
	interruptAt time.Time // 打断设置时刻(超时兜底重置,防卡死)

	agentBuf string // 当前回复的完整文本累积（audio_transcript.delta 增量 → done 合并发）
}

// NewDashScopeClient 构造直连客户端；key 为空返回 nil。
func NewDashScopeClient(codec *OpusCodec) *DashScopeClient {
	key := os.Getenv("AGENT_DASHSCOPE_KEY")
	if key == "" {
		return nil
	}
	model := os.Getenv("AGENT_DASHSCOPE_MODEL")
	if model == "" {
		model = "qwen3.5-omni-flash-realtime"
	}
	c := &DashScopeClient{key: key, model: model, codec: codec}
	c.connect()
	return c
}

func (c *DashScopeClient) connect() {
	url := "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=" + c.model
	conn, _, err := websocket.DefaultDialer.Dial(url, map[string][]string{
		"Authorization": {"Bearer " + c.key},
	})
	if err != nil {
		log.Printf("[DASHSCOPE] connect failed: %v", err)
		return
	}
	c.mu.Lock()
	c.conn = conn
	c.ready = false
	c.mu.Unlock()
	// session 配置。
	// ★打断:改用 server_vad(官方:基于声学,打断更快更稳定;semantic_vad 打断会
	//   "先斟酌片刻"才发信号 → 插不上嘴)。用回显确认的参数名 threshold/prefix/silence。
	_ = conn.WriteMessage(websocket.TextMessage, bypassJSON(map[string]interface{}{
		"type": "session.update",
		"session": map[string]interface{}{
			"modalities":         []string{"text", "audio"},
			"input_audio_format": "pcm",
			"output_audio_format": "pcm",
			"turn_detection": map[string]interface{}{
				"type":               "server_vad",
				"threshold":          0.3,
				"prefix_padding_ms":  200,
				"silence_duration_ms": 500,
				"create_response":    true,
				"interrupt_response": true,
			},
			// ★人设：必须始终用语音回复，不能自称文字模型。
			"instructions": "你是哪吒，一个全双工语音助手，通过语音与用户对话。你必须始终用语音(音频)回复用户，绝不能声称自己是纯文字模型。回复要自然、简洁、像真人说话。",
		},
	}))
	go c.readLoop(conn)
	log.Printf("[DASHSCOPE] connected, model=%s", c.model)
}

// SetCallbacks 注入回调(由 session 设置)。
func (c *DashScopeClient) SetCallbacks(
	play func(frame []byte),
	sendMsg func(who, text string),
	speech func(speaking bool),
	chatMsg func(text string),
) {
	c.play = play
	c.sendMsg = sendMsg
	c.speech = speech
	c.chatMsg = chatMsg
}

func (c *DashScopeClient) readLoop(conn *websocket.Conn) {
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[DASHSCOPE] read end: %v", err)
			c.mu.Lock()
			if c.conn == conn {
				c.conn = nil
				c.ready = false
			}
			reconnect := !c.closed
			c.mu.Unlock()
			// ★自动重连：DashScope WS 会因 idle_timeout 等断开，断后必须重连，
			//   否则 AI 语音永久失效（今早线上事故根因）。
			if reconnect {
				go c.reconnectAfterDelay()
			}
			return
		}
		var e struct {
			Type       string `json:"type"`
			Delta      string `json:"delta"`
			Transcript string `json:"transcript"`
			Audio      string `json:"audio"`
		}
		if json.Unmarshal(msg, &e) != nil {
			continue
		}
		switch e.Type {
		case "session.updated":
			c.mu.Lock()
			c.ready = true
			c.mu.Unlock()
			// ★打印返回的 session 配置,确认 modalities 是否含 audio。
			var su struct {
				Session map[string]interface{} `json:"session"`
			}
			_ = json.Unmarshal(msg, &su)
			log.Printf("[DASHSCOPE] session ready: %s", msg)
			_ = su
		case "input_audio_buffer.speech_started":
			log.Printf("[DASHSCOPE] speech started")
			if c.speech != nil {
				c.speech(true)
			}
		case "input_audio_buffer.speech_stopped":
			log.Printf("[DASHSCOPE] speech stopped")
			if c.speech != nil {
				c.speech(false)
			}
		case "conversation.item.input_audio_transcription.completed":
			if c.sendMsg != nil {
				c.sendMsg("user", e.Transcript)
			}
			log.Printf("[DASHSCOPE] user: %s", e.Transcript)
		case "response.audio.delta", "response.output_audio.delta":
			// ★打断后丢弃旧回复的残余音频(否则旧回复播完才轮到新回复 → 插不上嘴)。
			//   超时兜底:打断 1s 后仍无新回复 → 重置标记(防卡死永久静音)。
			//   1s 足够 cancel 生效;若无旧回复残余,audio.delta 会很快恢复正常。
			c.mu.Lock()
			interrupted := c.interrupted
			if interrupted && time.Since(c.interruptAt) > 1*time.Second {
				interrupted = false
				c.interrupted = false
			}
			c.mu.Unlock()
			if interrupted {
				continue
			}
			// 回复音频(PCM) → Opus → 回手机。
			// ★DashScope 音频在 `delta` 字段（不是 `audio`）。
			// ★delta 是大块 PCM(≈320ms)，必须切 20ms 帧逐帧编码——整段一次编码
			//   超 libopus 单帧上限(5760samples@48k)会整体丢弃。
			buf, err := base64.StdEncoding.DecodeString(e.Delta)
			if err != nil {
				continue
			}
			if c.codec == nil || c.play == nil {
				continue
			}
			pcm := make([]int16, len(buf)/2)
			for i := range pcm {
				pcm[i] = int16(buf[i*2]) | int16(buf[i*2+1])<<8
			}
			// ★切 20ms 帧(24k mono):480 samples/帧。
			const frameSamples = 480
			for start := 0; start < len(pcm); start += frameSamples {
				end := start + frameSamples
				if end > len(pcm) {
					end = len(pcm)
				}
				chunk := pcm[start:end]
				if len(chunk) < frameSamples {
					// 尾帧不足 20ms → 零填充补齐，避免 libopus 帧长不整报错。
					full := make([]int16, frameSamples)
					copy(full, chunk)
					chunk = full
				}
				opus, err := c.codec.EncodeFrom24k(chunk)
				if err != nil {
					continue
				}
				c.play(opus)
			}
		case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
			// ★增量累积：不逐条发（会碎字），等 done 合并发完整文本。
			c.agentBuf += e.Delta
		case "response.audio_transcript.done", "response.output_audio_transcript.done":
			// 优先用 done 携带的完整 transcript（若为空则用累积的 delta）。
			full := e.Transcript
			if full == "" {
				full = c.agentBuf
			}
			c.agentBuf = ""
			if c.chatMsg != nil && full != "" {
				c.chatMsg(full)
			}
			if c.sendMsg != nil && full != "" {
				c.sendMsg("agent", full)
			}
			log.Printf("[DASHSCOPE] agent: %s", full)
		case "response.created", "response.done":
			// ★新回复开始:清除打断标记,恢复播放新回复的音频。
			if e.Type == "response.created" {
				c.mu.Lock()
				c.interrupted = false
				c.mu.Unlock()
			}
		case "error":
			log.Printf("[DASHSCOPE] error: %s", msg)
		}
	}
}

// reconnectAfterDelay 断开后延迟重连(3s,防风暴);进程退出则不重连。
func (c *DashScopeClient) reconnectAfterDelay() {
	if c.closed {
		return
	}
	time.Sleep(3 * time.Second)
	c.mu.Lock()
	if c.closed || c.conn != nil {
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()
	c.connect()
}

// Close 关闭连接并禁止重连(进程退出)。
func (c *DashScopeClient) Close() {
	c.mu.Lock()
	c.closed = true
	conn := c.conn
	c.conn = nil
	c.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

// AppendPCM16k 发送手机语音到 DashScope。
func (c *DashScopeClient) AppendPCM16k(pcm []int16) {
	if c == nil {
		return
	}
	c.mu.Lock()
	conn := c.conn
	ready := c.ready
	c.mu.Unlock()
	if conn == nil {
		return
	}
	if !ready {
		return
	}
	buf := make([]byte, len(pcm)*2)
	for i, s := range pcm {
		buf[i*2] = byte(s)
		buf[i*2+1] = byte(s >> 8)
	}
	_ = conn.WriteMessage(websocket.TextMessage, bypassJSON(map[string]interface{}{
		"type":  "input_audio_buffer.append",
		"audio": base64.StdEncoding.EncodeToString(buf),
	}))
}

// Interrupt 打断回复(用户插话)。
func (c *DashScopeClient) Interrupt() {
	c.mu.Lock()
	c.interrupted = true // 丢弃之后到达的旧回复 audio.delta
	c.interruptAt = time.Now()
	c.agentBuf = "" // 清旧回复累积文本,避免打断后文本拼接错乱
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return
	}
	_ = conn.WriteMessage(websocket.TextMessage, bypassJSON(map[string]interface{}{
		"type": "response.cancel",
	}))
}
