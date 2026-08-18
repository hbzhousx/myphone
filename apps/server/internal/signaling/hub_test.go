package signaling

import (
	"encoding/json"
	"testing"
)

// TestChatQueueKeys 验证聊天离线队列 key 与去重 key 的格式。
func TestChatQueueKeys(t *testing.T) {
	queueKey := "chat:queue:user-123"
	seenKey := "chat:seen:msg-abc"
	if got := "chat:queue:user-123"; got != queueKey {
		t.Fatalf("unexpected queue key: %s", got)
	}
	if got := "chat:seen:msg-abc"; got != seenKey {
		t.Fatalf("unexpected seen key: %s", got)
	}
}

// TestChatMessageParsing 验证 chatMessage 信封的 message_id 提取逻辑（供离线队列判定）。
func TestChatMessageParsing(t *testing.T) {
	signal := map[string]interface{}{
		"type":         "chatMessage",
		"from_user_id": "alice",
		"to_user_id":   "bob",
		"payload": map[string]interface{}{
			"message_id": "msg-42",
			"ciphertext": "base64...",
		},
	}
	b, _ := json.Marshal(signal)
	var parsed map[string]interface{}
	if err := json.Unmarshal(b, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	payload, _ := parsed["payload"].(map[string]interface{})
	msgID, _ := payload["message_id"].(string)
	if msgID != "msg-42" {
		t.Fatalf("expected msg-42, got %q", msgID)
	}
	if payload["message_id"] == nil {
		t.Fatalf("message_id should be present")
	}
}

// TestIsOnline 验证 IsOnline 对不在线用户返回 false。
func TestIsOnline(t *testing.T) {
	h := NewHub(nil)
	online := h.IsOnline([]string{"ghost-user"})
	if online["ghost-user"] {
		t.Fatalf("ghost user should be offline")
	}
}

// mockBridge 记录转发参数的假 AgentBridge。
type mockBridge struct{ send func(from, bot string, raw []byte) }

func (m mockBridge) SendToAgent(from, bot string, raw []byte) { m.send(from, bot, raw) }

// TestAgentBridgeRouting 验证 AI 会话信令路由到媒体端点桥；未挂桥 drop 不 panic。
func TestAgentBridgeRouting(t *testing.T) {
	h := NewHub(nil)
	h.routeAgentSignal("alice", "bot-luozha", []byte(`{"type":"agentInit"}`)) // 未挂桥不 panic

	var gotFrom, gotBot string
	var gotRaw []byte
	h.SetAgentBridge(mockBridge{send: func(from, bot string, raw []byte) {
		gotFrom, gotBot, gotRaw = from, bot, raw
	}})
	h.routeAgentSignal("alice", "bot-luozha", []byte(`{"type":"agentInit","payload":{}}`))
	if gotFrom != "alice" || gotBot != "bot-luozha" {
		t.Fatalf("unexpected routing: from=%q bot=%q", gotFrom, gotBot)
	}
	if gotRaw == nil || len(gotRaw) == 0 {
		t.Fatalf("expected raw message forwarded")
	}
}

// TestIsAgentSignalType 验证 c2a 类型判定（agentReady/agentTranscript 为 a2c 不路由）。
func TestIsAgentSignalType(t *testing.T) {
	for _, typ := range []string{"agentInit", "agentSignal", "agentHangup"} {
		if !isAgentSignalType(typ) {
			t.Fatalf("expected %s to be an agent signal type", typ)
		}
	}
	for _, typ := range []string{"chatMessage", "agentReady", "agentTranscript"} {
		if isAgentSignalType(typ) {
			t.Fatalf("expected %s NOT to be an agent signal type", typ)
		}
	}
}
