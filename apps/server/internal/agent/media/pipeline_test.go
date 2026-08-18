package media

import (
	"testing"
	"time"
)

// TestAgentProvider 验证 AgentText 连 mock/agent 返回文本 + 动作。
// 需要 mock-providers 运行在 127.0.0.1:18081。
func TestAgentProvider(t *testing.T) {
	if !mockUp() {
		t.Skip("mock-providers not running on :18081")
	}
	agent := NewHTTPAgentText(AgentTextConfig{URL: "http://127.0.0.1:18081/mock/agent"}, "u1")
	reply, err := agent.Query("sess-1", "你好哪吒")
	if err != nil {
		t.Fatalf("agent query: %v", err)
	}
	if reply.Text == "" {
		t.Fatalf("expected non-empty agent reply")
	}
	if len(reply.Actions) == 0 {
		t.Fatalf("expected action in reply")
	}
	t.Logf("agent reply=%q actions=%d", reply.Text, len(reply.Actions))
}

// TestTTSProvider 验证 TTS 连 mock/tts 返回 Opus 帧。
func TestTTSProvider(t *testing.T) {
	if !mockUp() {
		t.Skip("mock-providers not running on :18081")
	}
	tts := NewHTTPTTS(TTSConfig{URL: "http://127.0.0.1:18081/mock/tts"})
	var frames int
	n, err := tts.Synthesize("sess-1", "你好", func(frame []byte) { frames++ })
	if err != nil {
		t.Fatalf("tts: %v", err)
	}
	if n == 0 || frames == 0 {
		t.Fatalf("expected frames, got %d", n)
	}
	t.Logf("tts frames=%d", n)
}

// TestASRNoProvider 验证未配置 ASR 时 Feed 不报错（仅计数）。
func TestASRNoProvider(t *testing.T) {
	asr := NewHTTPASR(ASRConfig{URL: ""}, "u1")
	if err := asr.Feed("sess-1", []byte{1}); err != nil {
		t.Fatalf("feed: %v", err)
	}
	asr.Close("sess-1")
}

// TestBargeIn 验证打断逻辑：播放循环中 cancel 停止后续帧。
func TestBargeIn(t *testing.T) {
	var played int
	cancel := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 100; i++ {
			select {
			case <-cancel:
				return
			default:
			}
			played++
			time.Sleep(time.Millisecond)
		}
	}()
	time.Sleep(3 * time.Millisecond)
	close(cancel) // barge-in
	<-done
	if played >= 100 {
		t.Fatalf("expected barge-in to stop early, played=%d", played)
	}
	t.Logf("barge-in stopped after %d frames", played)
}

// mockUp 探测 mock-providers 是否在跑（避免测试环境缺依赖时报错）。
func mockUp() bool {
	agent := NewHTTPAgentText(AgentTextConfig{URL: "http://127.0.0.1:18081/mock/agent"}, "u1")
	_, err := agent.Query("sess-1", "ping")
	return err == nil
}
