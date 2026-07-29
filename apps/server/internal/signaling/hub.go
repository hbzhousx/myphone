package signaling

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin:     func(r *http.Request) bool { return true },
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

func (h *Hub) sendToUser(userID string, message []byte) {
	h.mu.RLock()
	client, ok := h.clients[userID]
	h.mu.RUnlock()
	if ok {
		select {
		case client.send <- message:
			h.TotalMessages++
		default:
		}
	}
}

func HandleWebSocket(hub *Hub, w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("userID").(string)
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade error: %v", err)
		return
	}
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
		var signal map[string]interface{}
		if err := json.Unmarshal(message, &signal); err != nil {
			continue
		}
		c.hub.callMu.Lock()
		if typ, ok := signal["type"].(string); ok {
			if cid, ok2 := signal["call_id"].(string); ok2 {
				switch typ {
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
		if toUserID, ok := signal["to_user_id"].(string); ok {
			c.hub.sendToUser(toUserID, message)
		}
	}
}

func (c *Client) writePump() {
	defer c.conn.Close()
	for message := range c.send {
		if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
			break
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
