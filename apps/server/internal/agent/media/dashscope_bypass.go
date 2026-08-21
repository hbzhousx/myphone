// DashScope 直连旁路诊断（联调用）：
// 收到手机真实语音 PCM16k 时，同时直连 DashScope Realtime API 发同一段音频，
// 确认「手机 PCM 是否能被 DashScope 识别」。绕开 qwen-audio-agent Gateway 集成层。
//
// 配置：AGENT_DASHSCOPE_KEY=<key> 时启用（仅测试，不用于生产）。
// 模型：AGENT_DASHSCOPE_MODEL（默认 qwen3.5-omni-flash-realtime）
package media

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"os"
	"sync"

	"github.com/gorilla/websocket"
)

func bypassJSON(v interface{}) []byte {
	b, _ := json.Marshal(v)
	return b
}

// DashScopeBypass 是 DashScope Realtime 直连旁路。
type DashScopeBypass struct {
	key     string
	model   string
	mu      sync.Mutex
	conn    *websocket.Conn
	ready   bool

	// 识别统计。
	recognitionHits int
}

// NewDashScopeBypass 构造旁路；key 为空则禁用。
func NewDashScopeBypass() *DashScopeBypass {
	key := os.Getenv("AGENT_DASHSCOPE_KEY")
	if key == "" {
		return nil
	}
	model := os.Getenv("AGENT_DASHSCOPE_MODEL")
	if model == "" {
		model = "qwen3.5-omni-flash-realtime"
	}
	b := &DashScopeBypass{key: key, model: model}
	b.connect()
	return b
}

func (b *DashScopeBypass) connect() {
	url := "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=" + b.model
	conn, _, err := websocket.DefaultDialer.Dial(url, map[string][]string{
		"Authorization": {"Bearer " + b.key},
	})
	if err != nil {
		log.Printf("[DASHSCOPE-BYPASS] connect failed: %v", err)
		return
	}
	b.mu.Lock()
	b.conn = conn
	b.ready = false
	b.mu.Unlock()
	// 发 session 配置(与 qwen-audio-agent 一致)。
	_ = conn.WriteMessage(websocket.TextMessage, bypassJSON(map[string]interface{}{
		"type": "session.update",
		"session": map[string]interface{}{
			"modalities":         []string{"text", "audio"},
			"input_audio_format": "pcm",
			"output_audio_format": "pcm",
			"turn_detection":     map[string]interface{}{"type": "semantic_vad"},
		},
	}))
	go b.readLoop(conn)
	log.Printf("[DASHSCOPE-BYPASS] connected, model=%s", b.model)
}

func (b *DashScopeBypass) readLoop(conn *websocket.Conn) {
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[DASHSCOPE-BYPASS] read end: %v", err)
			b.mu.Lock()
			if b.conn == conn {
				b.conn = nil
			}
			b.mu.Unlock()
			return
		}
		var e struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(msg, &e) != nil {
			continue
		}
		switch e.Type {
		case "session.updated":
			b.mu.Lock()
			b.ready = true
			b.mu.Unlock()
			log.Printf("[DASHSCOPE-BYPASS] session ready")
		case "input_audio_buffer.speech_started":
			log.Printf("[DASHSCOPE-BYPASS] ★ SPEECH_STARTED — 手机语音被识别!")
			b.mu.Lock()
			b.recognitionHits++
			b.mu.Unlock()
		case "conversation.item.input_audio_transcription.completed":
			var t struct {
				Transcript string `json:"transcript"`
			}
			_ = json.Unmarshal(msg, &t)
			log.Printf("[DASHSCOPE-BYPASS] ★ TRANSCRIPT: %s", t.Transcript)
		case "error":
			log.Printf("[DASHSCOPE-BYPASS] error: %s", msg)
		}
	}
}

// AppendPCM16k 发送一帧 PCM16k 到 DashScope(旁路)。
func (b *DashScopeBypass) AppendPCM16k(pcm []int16) {
	if b == nil {
		return
	}
	b.mu.Lock()
	conn := b.conn
	ready := b.ready
	b.mu.Unlock()
	if conn == nil || !ready {
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
