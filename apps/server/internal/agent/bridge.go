// Package agent 实现 myphone-server → 媒体端点（Pion WebRTC 进程）的出站桥。
//
// 方向：
//   - c2a：用户客户端经 hub 转发的 AI 会话信令（agentInit/agentSignal/agentHangup）
//     包成 {direction:'c2a', user_id, type, payload} 发给媒体端点；
//   - a2c：媒体端点回复（agentReady/agentTranscript/agentHangup/chatMessage 等）
//     解包 {direction:'a2c', user_id, type, payload} → 拼 ChatSignal 信封
//     （from_user_id=bot-luozha）→ 经 hub 推给用户。
//
// 断线自动指数退避重连；AGENT_MEDIA_WS_URL 未配置时全链路静默降级（drop+日志）。
package agent

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/myphone/server/internal/signaling"
)

// botUserID 是服务器上机器人的固定用户 id（客户端 / 服务端 bot 匹配共用）。
const botUserID = "bot-luozha"

// Bridge 是 myphone-server 与媒体端点之间的双向桥。
type Bridge struct {
	hub   *signaling.Hub
	url   string
	token string

	mu   sync.Mutex
	conn *websocket.Conn
	stop chan struct{}
}

// NewBridge 构造桥。url 为空时 Run() 直接返回（媒体端点未部署）。
func NewBridge(hub *signaling.Hub, url, token string) *Bridge {
	return &Bridge{hub: hub, url: url, token: token, stop: make(chan struct{})}
}

// Run 阻塞运行：连接媒体端点并转发 a2c 消息；断线退避重连。
func (b *Bridge) Run() {
	if b.url == "" {
		log.Printf("[AGENT-BRIDGE] AGENT_MEDIA_WS_URL empty — media endpoint disabled")
		return
	}
	backoff := 2 * time.Second
	for {
		select {
		case <-b.stop:
			return
		default:
		}
		if err := b.connectAndServe(); err != nil {
			log.Printf("[AGENT-BRIDGE] disconnected: %v (reconnect in %v)", err, backoff)
		}
		select {
		case <-b.stop:
			return
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

// Stop 停止桥（Run 返回）。保留供优雅关停使用。
func (b *Bridge) Stop() { close(b.stop) }

func (b *Bridge) connectAndServe() error {
	headers := http.Header{}
	if b.token != "" {
		headers.Set("Authorization", "Bearer "+b.token)
	}
	conn, _, err := websocket.DefaultDialer.Dial(b.url, headers)
	if err != nil {
		return err
	}
	b.mu.Lock()
	b.conn = conn
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		if b.conn == conn {
			b.conn = nil
		}
		b.mu.Unlock()
		_ = conn.Close()
	}()
	log.Printf("[AGENT-BRIDGE] connected to media endpoint %s", b.url)

	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		b.handleFromAgent(message)
	}
}

// SendToAgent 把一条 c2a 信令（用户 → bot）转发给媒体端点。
// hub.readPump 在路由到 bot- 前缀且类型 ∈ {agentInit,agentSignal,agentHangup} 时调用。
func (b *Bridge) SendToAgent(fromID, botID string, raw []byte) {
	b.mu.Lock()
	conn := b.conn
	b.mu.Unlock()
	if conn == nil {
		log.Printf("[AGENT-BRIDGE] drop c2a (bridge down): from=%s to=%s", fromID, botID)
		return
	}
	var sig map[string]interface{}
	if err := json.Unmarshal(raw, &sig); err != nil {
		log.Printf("[AGENT-BRIDGE] drop c2a bad json: %s", raw)
		return
	}
	env := map[string]interface{}{
		"direction": "c2a",
		"user_id":   fromID,
		"type":      sig["type"],
		"payload":   sig["payload"],
	}
	out, _ := json.Marshal(env)
	if err := conn.WriteMessage(websocket.TextMessage, out); err != nil {
		log.Printf("[AGENT-BRIDGE] c2a write failed: %v", err)
	}
}

// handleFromAgent 处理媒体端点的 a2c 消息，拼 ChatSignal 信封推给用户。
func (b *Bridge) handleFromAgent(message []byte) {
	var env struct {
		Direction string                 `json:"direction"`
		UserID    string                 `json:"user_id"`
		Type      string                 `json:"type"`
		Payload   map[string]interface{} `json:"payload"`
	}
	if err := json.Unmarshal(message, &env); err != nil {
		log.Printf("[AGENT-BRIDGE] bad a2c json: %v", err)
		return
	}
	if env.Direction != "a2c" || env.UserID == "" {
		log.Printf("[AGENT-BRIDGE] ignore non-a2c from agent: %s", message)
		return
	}
	// 补齐 ChatSignal 信封（from=bot-luozha），交给 hub 推给用户。
	out := map[string]interface{}{
		"type":         env.Type,
		"from_user_id": botUserID,
		"to_user_id":   env.UserID,
		"payload":      env.Payload,
	}
	raw, _ := json.Marshal(out)
	signaling.SendToUser(b.hub, env.UserID, raw)
	log.Printf("[AGENT-BRIDGE] a2c type=%s to=%s", env.Type, env.UserID)
}
