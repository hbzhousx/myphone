// media-agent-stub 是 v1.50 AI 通话的**桩媒体端点**（Phase B 可测性用）。
//
// 行为（不建立真实 WebRTC/音频）：
//   - 连接（校验 AGENT_BRIDGE_TOKEN）后收到 c2a agentInit → 立即回 agentReady{connected}
//     + agentTranscript（欢迎语）+ 一条 chatMessage 动作卡片（演示聊天页历史回流）；
//   - 周期回假字幕（agentTranscript：用户/Agent 交替）；
//   - 收到 agentHangup 或运行 60s → 回 agentReady{ended}。
//
// 用法：
//   AGENT_MEDIA_WS_URL=ws://127.0.0.1:8090/bridge AGENT_BRIDGE_TOKEN=dev go run ./cmd/media-agent-stub
package main

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func main() {
	addr := os.Getenv("AGENT_LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8090"
	}
	http.HandleFunc("/bridge", handleBridge)
	log.Printf("[STUB] media-agent-stub listening on %s (token ok=%v)", addr, os.Getenv("AGENT_BRIDGE_TOKEN") != "")
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("[STUB] server error: %v", err)
	}
}

func handleBridge(w http.ResponseWriter, r *http.Request) {
	// 校验桥接 token（与服务端配置一致）。
	if want := os.Getenv("AGENT_BRIDGE_TOKEN"); want != "" {
		got := ""
		auth := r.Header.Get("Authorization")
		if len(auth) > 7 && auth[:7] == "Bearer " {
			got = auth[7:]
		}
		if got != want {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[STUB] upgrade error: %v", err)
		return
	}
	defer conn.Close()
	log.Printf("[STUB] bridge connected")

	mu := &sync.Mutex{}
	send := func(env map[string]interface{}) {
		mu.Lock()
		defer mu.Unlock()
		_ = conn.WriteMessage(websocket.TextMessage, mustJSON(env))
	}

	// 每会话定时器：60s 后自动 ended（防止测试忘记挂断）。
	var userIDMu sync.Mutex
	sessionUser := "?"
	timer := time.AfterFunc(60*time.Second, func() {
		userIDMu.Lock()
		u := sessionUser
		userIDMu.Unlock()
		send(endedEnv(u, "timeout"))
	})

	// 消息分发循环。
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[STUB] read error: %v", err)
			return
		}
		var env struct {
			Direction string                 `json:"direction"`
			UserID    string                 `json:"user_id"`
			Type      string                 `json:"type"`
			Payload   map[string]interface{} `json:"payload"`
		}
		if err := json.Unmarshal(msg, &env); err != nil {
			log.Printf("[STUB] bad c2a: %v", err)
			continue
		}
		if env.Direction != "c2a" {
			continue
		}
		userID := env.UserID
		userIDMu.Lock()
		sessionUser = userID
		userIDMu.Unlock()
		switch env.Type {
		case "agentInit":
			log.Printf("[STUB] agentInit from=%s", userID)
			send(readyEnv(userID, "connected", ""))
			send(transcriptEnv(userID, 1, "agent", "你好，我是哪吒 AI 助手，有什么可以帮你？", true))
			send(actionChatMessage(userID))
			// 周期假字幕：用户/Agent 交替，演示实时字幕 + 状态机。
			go fakeTranscripts(userID, send)
		case "agentHangup":
			log.Printf("[STUB] agentHangup from=%s", userID)
			timer.Stop()
			send(endedEnv(userID, "user_hangup"))
		}
	}
}

// fakeTranscripts 周期发几条假字幕（seq 递增）。
func fakeTranscripts(userID string, send func(map[string]interface{})) {
	seq := 2
	for i := 0; i < 4; i++ {
		time.Sleep(3 * time.Second)
		who := "user"
		text := "（示例用户语音转写内容……）"
		if i%2 == 1 {
			who = "agent"
			text = "（示例 AI 回复内容……）"
		}
		send(transcriptEnv(userID, seq, who, text, true))
		seq++
	}
}

// ---- 构造 a2c 信封（与 internal/agent/bridge.go 的 a2c 约定一致）----

func readyEnv(userID, state, reason string) map[string]interface{} {
	p := map[string]interface{}{"session_id": "stub", "state": state}
	if reason != "" {
		p["reason"] = reason
	}
	return map[string]interface{}{"direction": "a2c", "user_id": userID, "type": "agentReady", "payload": p}
}

func transcriptEnv(userID string, seq int, who, text string, final bool) map[string]interface{} {
	return map[string]interface{}{
		"direction": "a2c", "user_id": userID, "type": "agentTranscript",
		"payload": map[string]interface{}{
			"session_id": "stub", "seq": seq, "who": who, "text": text, "is_final": final,
		},
	}
}

func endedEnv(userID, reason string) map[string]interface{} {
	return map[string]interface{}{"direction": "a2c", "user_id": userID, "type": "agentReady", "payload": map[string]interface{}{"session_id": "stub", "state": "ended", "reason": reason}}
}

// actionChatMessage 发一条 chatMessage（bot 明文旁路）演示动作卡片落库。
func actionChatMessage(userID string) map[string]interface{} {
	plain, _ := json.Marshal(map[string]interface{}{
		"kind": "action",
		"body": "示例动作",
		"agent_payload": map[string]interface{}{
			"title":  "示例动作：发送一条通知",
			"status": "done",
			"detail": "这是媒体端点下发的动作卡片示例",
		},
	})
	return map[string]interface{}{
		"direction": "a2c", "user_id": userID, "type": "chatMessage",
		"payload": map[string]interface{}{
			"message_id": "stub-action-" + time.Now().Format("150405"),
			"ciphertext": base64.StdEncoding.EncodeToString(plain),
			"counter":    0,
			"plaintext":  true,
		},
	}
}

func mustJSON(v interface{}) []byte {
	b, _ := json.Marshal(v)
	return b
}
