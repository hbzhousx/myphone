// 媒体端点侧的 WS 桥接服务：接收 myphone-server 的 c2a 信令，分发到 [Manager]；
// 把 [Manager] 的 a2c 信令经同一条 WS 回推给服务器。
package media

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
)

var wsUpgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// BridgeServer 持有当前服务器桥连接，向 Manager 提供 [Signaling] 实现。
type BridgeServer struct {
	token   string
	manager *Manager

	mu   sync.Mutex
	conn *websocket.Conn
}

func NewBridgeServer(token string, manager *Manager) *BridgeServer {
	return &BridgeServer{token: token, manager: manager}
}

// Handler 是 /bridge 的 HTTP handler（校验 token 后升级为 WS）。
func (bs *BridgeServer) Handler(w http.ResponseWriter, r *http.Request) {
	if bs.token != "" {
		got := ""
		auth := r.Header.Get("Authorization")
		if len(auth) > 7 && auth[:7] == "Bearer " {
			got = auth[7:]
		}
		if got != bs.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
	}
	conn, err := wsUpgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[MEDIA-BRIDGE] upgrade error: %v", err)
		return
	}
	bs.mu.Lock()
	if bs.conn != nil {
		_ = bs.conn.Close() // 只保留最新一条服务器连接
	}
	bs.conn = conn
	bs.mu.Unlock()
	defer func() {
		bs.mu.Lock()
		if bs.conn == conn {
			bs.conn = nil
		}
		bs.mu.Unlock()
		_ = conn.Close()
	}()
	log.Printf("[MEDIA-BRIDGE] server bridge connected")

	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[MEDIA-BRIDGE] read error: %v", err)
			return
		}
		bs.handleFromServer(msg)
	}
}

// SendToServer 实现 [Signaling]：把 a2c 信令经当前连接回推 myphone-server。
func (bs *BridgeServer) SendToServer(userID, typ string, payload map[string]interface{}) {
	bs.mu.Lock()
	conn := bs.conn
	bs.mu.Unlock()
	if conn == nil {
		log.Printf("[MEDIA-BRIDGE] drop a2c (no server connection): to=%s type=%s", userID, typ)
		return
	}
	env := map[string]interface{}{
		"direction": "a2c",
		"user_id":   userID,
		"type":      typ,
		"payload":   payload,
	}
	out, _ := json.Marshal(env)
	if err := conn.WriteMessage(websocket.TextMessage, out); err != nil {
		log.Printf("[MEDIA-BRIDGE] a2c write failed: %v", err)
	}
}

// handleFromServer 处理 c2a 信令，分发到 Manager。
func (bs *BridgeServer) handleFromServer(message []byte) {
	var env struct {
		Direction string                 `json:"direction"`
		UserID    string                 `json:"user_id"`
		Type      string                 `json:"type"`
		Payload   map[string]interface{} `json:"payload"`
	}
	if err := json.Unmarshal(message, &env); err != nil {
		log.Printf("[MEDIA-BRIDGE] bad c2a: %v", err)
		return
	}
	if env.Direction != "c2a" {
		return
	}
	switch env.Type {
	case "agentInit":
		sessionID, _ := env.Payload["session_id"].(string)
		bs.manager.HandleInit(env.UserID, sessionID)
	case "agentSignal":
		bs.manager.HandleSignal(env.UserID, env.Payload)
	case "agentHangup":
		bs.manager.HandleHangup(env.UserID)
	default:
		log.Printf("[MEDIA-BRIDGE] ignore c2a type=%s", env.Type)
	}
}
