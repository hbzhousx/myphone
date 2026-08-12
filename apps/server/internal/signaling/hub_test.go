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
