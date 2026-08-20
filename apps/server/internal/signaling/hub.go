package signaling

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"
)

const (
	wsWriteWait    = 10 * time.Second
	wsPongWait     = 45 * time.Second
	wsPingInterval = (wsPongWait * 9) / 10 // send pings at 90% of pong timeout
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin:     func(r *http.Request) bool { return true },
	HandshakeTimeout: 10 * time.Second,
}

type Client struct {
	hub       *Hub
	conn      *websocket.Conn
	send      chan []byte
	userID    string
	Connected time.Time
}

// 聊天离线队列参数。
const (
	chatQueueTTL     = 24 * time.Hour // 队列保留时长（= 消息过期时间）
	chatSeenTTL      = 48 * time.Hour // 去重窗口
	chatQueueKey     = "chat:queue:%s"
	chatSeenKey      = "chat:seen:%s"
)

// AgentBridge 转发 AI 会话信令（agentInit/agentSignal/agentHangup）到媒体端点。
// 由 internal/agent.Bridge 实现；未挂载（nil）时 routeAgentSignal drop+日志。
type AgentBridge interface {
	SendToAgent(fromID, botID string, raw []byte)
}

// 连接风暴节流：同一用户窗口内注册次数超限则丢弃（防双 WS 互踢风暴）。
// ★阈值要足够高，只拦真正的病态风暴(几十次/秒)，不能误伤正常重连
//   （服务器重启后所有客户端同时退避重连可能瞬时几十次）。
const (
	connStormWindow = 8 * time.Second // 统计窗口
	connStormMax    = 50              // 窗口内最大注册次数
)

type Hub struct {
	clients    map[string]*Client
	register   chan *Client
	unregister chan *Client
	mu         sync.RWMutex

	// 连接风暴追踪：userID → 最近注册时间戳队列。
	connRecent map[string][]time.Time

	// Redis 客户端（可为 nil：聊天离线消息退化为「离线即丢弃」，不影响通话中继）。
	redis *redis.Client

	// agentBridge 媒体端点桥（v1.50 AI 通话）；nil 时 AI 会话信令 drop+日志。
	agentBridge AgentBridge

	TotalMessages  int64
	CallsActive    int
	CallsCompleted int64
	StartTime      time.Time
	ActiveCallIDs  map[string]bool
	callMu         sync.Mutex
}

// SetAgentBridge 挂载媒体端点桥（main 构造 agent.NewBridge 后调用）。
func (h *Hub) SetAgentBridge(b AgentBridge) {
	h.mu.Lock()
	h.agentBridge = b
	h.mu.Unlock()
}

func NewHub(redisClient *redis.Client) *Hub {
	return &Hub{
		clients:       make(map[string]*Client),
		register:      make(chan *Client),
		unregister:    make(chan *Client),
		redis:         redisClient,
		StartTime:     time.Now(),
		ActiveCallIDs: make(map[string]bool),
		connRecent:    make(map[string][]time.Time),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			// 连接风暴节流：窗口内注册过密 → 丢弃本次，避免双 WS 互踢风暴
			// （新连接踢旧连接、旧连接又重连，形成高频 connect/disconnect）。
			h.mu.Lock()
			now := time.Now()
			recent := h.connRecent[client.userID]
			recent = append(recent, now)
			cutoff := now.Add(-connStormWindow)
			i := 0
			for i < len(recent) && recent[i].Before(cutoff) {
				i++
			}
			recent = recent[i:]
			if len(recent) > connStormMax {
				h.connRecent[client.userID] = recent
				h.mu.Unlock()
				log.Printf("client connect storm (throttled): %s (%d in %s)", client.userID, len(recent), connStormWindow)
				client.conn.Close()
				continue
			}
			h.connRecent[client.userID] = recent

			// 只覆盖 map 指向最新连接，不主动 close 旧连接。
			// ★不要 close 旧连接：客户端多连接同时连时，close 会误杀刚建立的新连接
			//   → 客户端感知断开 → 重连 → 又关 → 死循环风暴（已实测）。
			//   旧连接会因客户端侧自然断开而 unregister（unregister 有身份保护）。
			h.clients[client.userID] = client
			h.mu.Unlock()
			log.Printf("client connected: %s", client.userID)
			// 上线后冲刷离线聊天队列（FIFO）。
			h.flushChatQueue(client.userID)
		case client := <-h.unregister:
			h.mu.Lock()
			// Only remove THIS connection from the map.  A reconnect may have
			// already replaced h.clients[userID] with a newer connection; blindly
			// deleting by userID would evict the fresh connection and make the
			// user appear offline to later signals ("drop: target not connected").
			if h.clients[client.userID] == client {
				delete(h.clients, client.userID)
				close(client.send)
			}
			h.mu.Unlock()
			log.Printf("client disconnected: %s", client.userID)
		}
	}
}

func (h *Hub) _sendToUser(userID string, message []byte) {
	// Hold the lock across the lookup AND the send: Run() removes a client and
	// closes client.send under the same lock when it unregisters, so this keeps
	// the send from racing a close. The select's default keeps it non-blocking
	// when the buffer is full.
	h.mu.RLock()
	client, ok := h.clients[userID]
	if !ok {
		h.mu.RUnlock()
		log.Printf("[SIGNAL] drop: target %s not connected", userID)
		return
	}
	defer h.mu.RUnlock()
	select {
	case client.send <- message:
		h.TotalMessages++
	default:
		log.Printf("[SIGNAL] drop: target %s send buffer full", userID)
	}
}

func sendToUser(hub *Hub, userID string, message []byte) {
	hub._sendToUser(userID, message)
}

// SendToUser 向指定用户推送一条信令（跨包使用：agent 桥接包回推用户）。
func SendToUser(hub *Hub, userID string, message []byte) {
	hub._sendToUser(userID, message)
}

// IsOnline returns true for each userID that currently has a live WebSocket
// connection.  Presence is derived from the hub's clients map, so it reflects
// "the app is running with an active signaling connection".
func (h *Hub) IsOnline(userIDs []string) map[string]bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	result := make(map[string]bool, len(userIDs))
	for _, id := range userIDs {
		_, ok := h.clients[id]
		result[id] = ok
	}
	return result
}

// HandlePresence answers POST /v1/users/presence.
// Request:  {"user_ids": ["<uuid>", ...]}
// Response: {"presence": {"<uuid>": "online"|"offline", ...}}
func HandlePresence(hub *Hub, w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserIDs []string `json:"user_ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	if len(req.UserIDs) == 0 {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"presence": map[string]string{},
		})
		return
	}
	online := hub.IsOnline(req.UserIDs)
	presence := make(map[string]string, len(online))
	for id, isOnline := range online {
		if isOnline {
			presence[id] = "online"
		} else {
			presence[id] = "offline"
		}
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"presence": presence})
}

func HandleWebSocket(hub *Hub, w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("userID").(string)
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade error: %v", err)
		return
	}
	// Set initial read deadline.  The pong handler extends it on each pong.
	conn.SetReadDeadline(time.Now().Add(wsPongWait))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(wsPongWait))
		return nil
	})

	client := &Client{
		hub:       hub,
		conn:      conn,
		send:      make(chan []byte, 256),
		userID:    userID,
		Connected: time.Now(),
	}
	hub.register <- client
	go client.writePump()
	go client.readPump()
}

func (c *Client) readPump() {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()
	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			break
		}
		// Each read extends the deadline — signals the client is alive.
		c.conn.SetReadDeadline(time.Now().Add(wsPongWait))

		var signal map[string]interface{}
		if err := json.Unmarshal(message, &signal); err != nil {
			continue
		}
		typ := signal["type"]
		callID := signal["call_id"]
		toUserID := signal["to_user_id"]
		fromUserID := signal["from_user_id"]

		c.hub.callMu.Lock()
		if s, ok := typ.(string); ok {
			if cid, ok2 := callID.(string); ok2 {
				switch s {
				case "offer", "answer":
					c.hub.ActiveCallIDs[cid] = true
				case "hangup":
					delete(c.hub.ActiveCallIDs, cid)
					c.hub.CallsCompleted++
				}
			}
		}
		c.hub.CallsActive = len(c.hub.ActiveCallIDs)
		c.hub.callMu.Unlock()

		log.Printf("[SIGNAL] recv type=%v call=%v from=%v to=%v", typ, callID, fromUserID, toUserID)

		// 客户端诊断上报：完整打印 payload，不转发（只用于定位"消息收到但不显示"）。
		if ts, ok := typ.(string); ok && ts == "chatDiag" {
			log.Printf("[CHAT-DIAG] %s", message)
			continue
		}

		if toID, ok := toUserID.(string); ok && toID != "" {
			// AI 会话信令（agentInit/agentSignal/agentHangup）→ 媒体端点桥。
			if s, ok := typ.(string); ok && isAgentSignalType(s) && strings.HasPrefix(toID, "bot-") {
				fromID, _ := fromUserID.(string)
				c.hub.routeAgentSignal(fromID, toID, message)
				continue
			}
			// 聊天消息：目标离线时进 Redis 短期队列，目标在线则按通话路径直转。
			if s, ok := typ.(string); ok && s == "chatMessage" {
				fromID, _ := fromUserID.(string)
				c.hub.handleChatMessage(signal, message, fromID, toID)
				continue
			}
			sendToUser(c.hub, toID, message)
		}
	}
}

// isAgentSignalType 判断是否为 AI 会话 c2a 信令（客户端 → bot → 媒体端点）。
func isAgentSignalType(t string) bool {
	switch t {
	case "agentInit", "agentSignal", "agentHangup":
		return true
	}
	return false
}

// routeAgentSignal 把 AI 会话信令交给媒体端点桥；桥未配置时 drop+日志。
func (h *Hub) routeAgentSignal(fromID, botID string, message []byte) {
	if h.agentBridge == nil {
		log.Printf("[AGENT-BRIDGE] drop agent signal from=%s to=%s: bridge not configured", fromID, botID)
		return
	}
	h.agentBridge.SendToAgent(fromID, botID, message)
}

// handleChatMessage 处理聊天消息中继。目标在线 → 直转；离线 → 入 Redis 队列（24h TTL）。
// 队列只存端到端密文信封 + 路由信息；服务器始终无法解密消息内容。
func (h *Hub) handleChatMessage(signal map[string]interface{}, raw []byte, fromID, toID string) {
	// ★机器人（哪吒）消息：@哪吒 走明文旁路（非 E2EE），服务器解析文本 →
	// 调外部智能体 → 拿回复发回发送方。
	if strings.HasPrefix(toID, "bot-") {
		h.handleBotMessage(signal, raw, fromID, toID)
		return
	}
	payload, _ := signal["payload"].(map[string]interface{})
	msgID, _ := payload["message_id"].(string)
	if msgID == "" {
		log.Printf("[CHAT] drop: chatMessage without message_id")
		return
	}

	if h.redis == nil {
		// Redis 不可用：退化为离线即丢弃（与通话中继行为一致）。
		if !h.IsOnline([]string{toID})[toID] {
			log.Printf("[CHAT] drop: target %s offline (no redis)", toID)
		} else {
			sendToUser(h, toID, raw)
		}
		return
	}

	ctx := context.Background()
	if h.IsOnline([]string{toID})[toID] {
		sendToUser(h, toID, raw)
		return
	}

	// 去重：同一 message_id 只入队一次（防重传双投）。
	seen, err := h.redis.SIsMember(ctx, fmt.Sprintf(chatSeenKey, msgID), msgID).Result()
	if err == nil && seen {
		log.Printf("[CHAT] drop: duplicate message_id=%s", msgID)
		return
	}
	if err == nil {
		h.redis.SAdd(ctx, fmt.Sprintf(chatSeenKey, msgID), msgID)
		h.redis.Expire(ctx, fmt.Sprintf(chatSeenKey, msgID), chatSeenTTL)
	}

	key := fmt.Sprintf(chatQueueKey, toID)
	h.redis.RPush(ctx, key, string(raw))
	h.redis.Expire(ctx, key, chatQueueTTL)
	log.Printf("[CHAT] queued for offline user=%s message_id=%s", toID, msgID)
}

// handleBotMessage 处理@哪吒消息：明文 payload（客户端对 bot- 前缀走明文旁路），
// 解析文本 → 调外部智能体 HTTP API（BOT_AGENT_URL，先定义接口）→ 拿回复 →
// 作为 bot 回复消息发回发送方。无智能体时返回占位回复。
func (h *Hub) handleBotMessage(signal map[string]interface{}, raw []byte, fromID, toID string) {
	payload, _ := signal["payload"].(map[string]interface{})
	// 明文消息：客户端对 bot 发明文（非棘轮密文），payload 里 ciphertext 是
	// base64 的明文 JSON？——用明文 kind 约定：客户端发 {kind:'text', body} 明文。
	var text string
	if ct, ok := payload["ciphertext"].(string); ok {
		// 明文旁路：客户端把 JSON 明文 base64 编码放 ciphertext。
		if b, err := base64.StdEncoding.DecodeString(ct); err == nil {
			var m map[string]interface{}
			if json.Unmarshal(b, &m) == nil {
				text, _ = m["body"].(string)
			}
		}
	}
	log.Printf("[BOT] from=%s to=%s text=%s", fromID, toID, text)
	if text == "" {
		text = "（空消息）"
	}

	// 调外部智能体（BOT_AGENT_URL 可配置；先定义接口 {user_id, text} → {text}）。
	reply := "哪吒收到：\"" + text + "\"。智能体对接开发中，稍后回复。"
	if url := os.Getenv("BOT_AGENT_URL"); url != "" {
		if resp, err := callBotAgent(url, fromID, text); err == nil {
			reply = resp
		}
	}

	// 构造 bot 回复信令发回发送方（明文，客户端 handleIncoming 识别 bot- 来源）。
	replyPayload := map[string]interface{}{
		"kind": "text",
		"body": reply,
	}
	replyCipher, _ := json.Marshal(replyPayload)
	replySignal := map[string]interface{}{
		"type":          "chatMessage",
		"from_user_id":  toID,
		"to_user_id":    fromID,
		"message_id":    "bot-reply-" + fmt.Sprint(time.Now().UnixMilli()),
		"payload": map[string]interface{}{
			"message_id": "bot-reply-" + fmt.Sprint(time.Now().UnixMilli()),
			"ciphertext": base64.StdEncoding.EncodeToString(replyCipher),
			"counter":    0,
			"plaintext":  true,
		},
	}
	replyRaw, _ := json.Marshal(replySignal)
	sendToUser(h, fromID, replyRaw)
	log.Printf("[BOT] reply sent to %s", fromID)
}

// callBotAgent 调外部智能体 HTTP API（先定义接口 {user_id, text} → {text}）。
func callBotAgent(url, userID, text string) (string, error) {
	body, _ := json.Marshal(map[string]string{"user_id": userID, "text": text})
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	return out.Text, nil
}

// flushChatQueue 上线时按 FIFO 冲刷离线聊天队列并清除。
func (h *Hub) flushChatQueue(userID string) {
	if h.redis == nil {
		return
	}
	ctx := context.Background()
	key := fmt.Sprintf(chatQueueKey, userID)
	items, err := h.redis.LRange(ctx, key, 0, -1).Result()
	if err != nil || len(items) == 0 {
		return
	}
	for _, it := range items {
		sendToUser(h, userID, []byte(it))
	}
	h.redis.Del(ctx, key)
	log.Printf("[CHAT] flushed %d queued messages for user=%s", len(items), userID)
}

func (c *Client) writePump() {
	ticker := time.NewTicker(wsPingInterval)
	defer func() {
		ticker.Stop()
		// Ensure the client is removed from the hub even if the read pump hasn't
		// noticed the failure yet (e.g. a half-open TCP connection whose reads
		// never error). Run() guards against double-removal.
		c.hub.unregister <- c
		c.conn.Close()
	}()
	for {
		select {
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if !ok {
				// The hub closed the channel.
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}
		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (h *Hub) Stats() map[string]interface{} {
	h.mu.RLock()
	online := len(h.clients)
	users := make([]map[string]interface{}, 0, online)
	for _, c := range h.clients {
		users = append(users, map[string]interface{}{
			"user_id":   c.userID,
			"connected": c.Connected.Format(time.RFC3339),
			"uptime":    time.Since(c.Connected).Round(time.Second).String(),
		})
	}
	h.mu.RUnlock()
	h.callMu.Lock()
	active := h.CallsActive
	completed := h.CallsCompleted
	h.callMu.Unlock()
	return map[string]interface{}{
		"online_users":    online,
		"total_messages":  h.TotalMessages,
		"calls_active":    active,
		"calls_completed": completed,
		"uptime":          time.Since(h.StartTime).Round(time.Second).String(),
		"users":           users,
	}
}
