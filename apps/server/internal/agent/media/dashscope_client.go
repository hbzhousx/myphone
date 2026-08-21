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

	mu          sync.Mutex
	conn        *websocket.Conn
	ready       bool
	appendCount int
	skipCount   int
	deltaCount  int

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
	// session 配置(与旁路一致,启用 semantic_vad)。
	_ = conn.WriteMessage(websocket.TextMessage, bypassJSON(map[string]interface{}{
		"type": "session.update",
		"session": map[string]interface{}{
			"modalities":         []string{"text", "audio"},
			"input_audio_format": "pcm",
			"output_audio_format": "pcm",
			"turn_detection":     map[string]interface{}{"type": "semantic_vad"},
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
			}
			c.mu.Unlock()
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
		// ★诊断：打印所有事件 type（前 200 字），定位音频回复事件格式。
		if e.Type != "session.updated" && e.Type != "input_audio_buffer.speech_started" {
			log.Printf("[DASHSCOPE] event: %s → %s", e.Type, msg)
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
			// 回复音频(PCM) → Opus → 回手机。
			// ★DashScope 音频在 `delta` 字段（不是 `audio`）。
			// ★delta 是大块 PCM(≈320ms)，必须切 20ms 帧逐帧编码——整段一次编码
			//   超 libopus 单帧上限(5760samples@48k)会整体丢弃。
			c.deltaCount++
			buf, err := base64.StdEncoding.DecodeString(e.Delta)
			if err != nil {
				if c.deltaCount%50 == 0 {
					log.Printf("[DASHSCOPE] audio.delta decode fail: %v", err)
				}
				continue
			}
			if c.codec == nil || c.play == nil {
				if c.deltaCount%50 == 0 {
					log.Printf("[DASHSCOPE] audio.delta skipped play=%v codec=%v", c.play != nil, c.codec != nil)
				}
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
					if c.deltaCount%50 == 0 {
						log.Printf("[DASHSCOPE] encode frame failed: %v (chunk=%d)", err, len(chunk))
					}
					continue
				}
				c.play(opus)
			}
			if c.deltaCount%50 == 0 {
				log.Printf("[DASHSCOPE] audio.delta #%d (pcm=%d samples → N frames)", c.deltaCount, len(pcm))
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
		case "error":
			log.Printf("[DASHSCOPE] error: %s", msg)
		}
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
		c.skipCount++
		if c.skipCount%100 == 0 {
			log.Printf("[DASHSCOPE] append skipped (not ready) count=%d", c.skipCount)
		}
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
	c.appendCount++
	if c.appendCount%100 == 0 {
		log.Printf("[DASHSCOPE] sent %d audio.append", c.appendCount)
	}
}

// Interrupt 打断回复(用户插话)。
func (c *DashScopeClient) Interrupt() {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return
	}
	_ = conn.WriteMessage(websocket.TextMessage, bypassJSON(map[string]interface{}{
		"type": "response.cancel",
	}))
}
