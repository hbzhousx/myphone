// mock-providers 是 v1.50 AI 通话的外部 provider 模拟，用于本地全链路闭环验证。
//
// 端点：
//   /mock/agent  POST {user_id, text} → {text, actions}
//   /mock/tts    POST {text} → 返回 Opus 帧（base64）——媒体端点原样播放
//   /mock/asr    WS 流式：媒体端点把用户 Opus 帧发来，mock 回文本
//
// ★零本地编解码：mock 不真正转码。TTS 返回固定静音 Opus 帧（可被 WebRTC
// 对端解码但无实际声音），ASR 收到任意帧即回一条测试文本。
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// 固定静音 Opus 帧（48kHz 20ms，payload 少量字节的静音包）。
// 说明：真静音 Opus 帧极小（~4-8 字节）；这里用一组重复的合法帧头，
// 对端可解码但听不到声音——足够验证"TTS 出站帧被播放"的链路。
var silentOpusFrame = []byte{0xf8, 0xff, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}

func main() {
	addr := os.Getenv("MOCK_LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:18081"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/mock/agent", handleAgent)
	mux.HandleFunc("/mock/tts", handleTTS)
	mux.HandleFunc("/mock/asr", handleASR)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	log.Printf("[MOCK] listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("[MOCK] server error: %v", err)
	}
}

// handleAgent 回 {text, actions}（回声 + 演示动作）。
func handleAgent(w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserID    string `json:"user_id"`
		Text      string `json:"text"`
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	log.Printf("[MOCK] agent query text=%q", req.Text)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"text": "（模拟智能体）你说了：" + req.Text,
		"actions": []map[string]interface{}{
			{"title": "模拟动作：记录你的话", "status": "done", "detail": req.Text},
		},
	})
}

// handleTTS 返回 Opus 帧流（base64 列表），媒体端点逐帧播放。
func handleTTS(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	log.Printf("[MOCK] tts text=%q frames=%d", req.Text, len(req.Text))
	// 每个字合成 ~0.5s 静音（24 帧 × 20ms）。
	frames := make([]string, 0, 24*len([]rune(req.Text)))
	for range []rune(req.Text) {
		for i := 0; i < 24; i++ {
			frames = append(frames, base64.StdEncoding.EncodeToString(silentOpusFrame))
		}
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"frames": frames})
}

// handleASR 流式：每收到若干帧回一条"测试识别文本"。
func handleASR(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[MOCK] asr upgrade error: %v", err)
		return
	}
	defer conn.Close()
	frameCount := 0
	seq := 0
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[MOCK] asr read error: %v", err)
			return
		}
		// 帧 = base64 的 Opus payload（JSON {frame}）。简化：直接当二进制。
		_ = msg
		frameCount++
		// 每 250 帧（~5s 语音）回一条最终识别文本。
		if frameCount%250 == 0 {
			seq++
			text := fmt.Sprintf("这是第 %d 条模拟识别文本", seq)
			out, _ := json.Marshal(map[string]interface{}{"text": text, "is_final": true})
			_ = conn.WriteMessage(websocket.TextMessage, out)
			log.Printf("[MOCK] asr final seq=%d text=%q", seq, text)
		}
	}
}

// 保证 time 被用到（ASR 回包节奏）。
var _ = time.Second
