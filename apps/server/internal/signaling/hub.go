package signaling

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
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

type Hub struct {
	clients    map[string]*Client
	register   chan *Client
	unregister chan *Client
	mu         sync.RWMutex

	TotalMessages  int64
	CallsActive    int
	CallsCompleted int64
	StartTime      time.Time
	ActiveCallIDs  map[string]bool
	callMu         sync.Mutex
}

func NewHub() *Hub {
	return &Hub{
		clients:       make(map[string]*Client),
		register:      make(chan *Client),
		unregister:    make(chan *Client),
		StartTime:     time.Now(),
		ActiveCallIDs: make(map[string]bool),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client.userID] = client
			h.mu.Unlock()
			log.Printf("client connected: %s", client.userID)
		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client.userID]; ok {
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

		if toID, ok := toUserID.(string); ok && toID != "" {
			sendToUser(c.hub, toID, message)
		}
	}
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
