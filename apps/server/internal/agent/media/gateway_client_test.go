// GatewayClient 单测：只锁 playback.clear 打断派发（★2026-09-06 补线）。
// dispatch 由 readLoop 协程调用，测试直接构造回调注入后同步调用。
package media

import "testing"

// gatewayEvent 构造与 readLoop 解码目标一致的匿名结构体值。
func gatewayEvent(eventType string) struct {
	Type       string `json:"type"`
	Audio      string `json:"audio"`
	SampleRate int    `json:"sampleRate"`
	Role       string `json:"role"`
	Content    string `json:"content"`
	Delta      string `json:"delta"`
	State      string `json:"state"`
	Message    string `json:"message"`
	ResponseId string `json:"responseId"`
} {
	return struct {
		Type       string `json:"type"`
		Audio      string `json:"audio"`
		SampleRate int    `json:"sampleRate"`
		Role       string `json:"role"`
		Content    string `json:"content"`
		Delta      string `json:"delta"`
		State      string `json:"state"`
		Message    string `json:"message"`
		ResponseId string `json:"responseId"`
	}{Type: eventType}
}

func TestGatewayPlaybackClearDispatch(t *testing.T) {
	g := &GatewayClient{}
	called := 0
	g.SetPlaybackClearHandler(func() { called++ })

	g.dispatch(gatewayEvent("playback.clear"))
	if called != 1 {
		t.Fatalf("playback.clear 应触发打断回调一次，实际 %d 次", called)
	}

	// 其他事件不触发。
	g.dispatch(gatewayEvent("voice.ready"))
	g.dispatch(gatewayEvent("voice.connection"))
	if called != 1 {
		t.Fatalf("非打断事件不应触发回调，实际 %d 次", called)
	}

	// 未注入回调时不 panic。
	(&GatewayClient{}).dispatch(gatewayEvent("playback.clear"))
}

func TestGatewaySetCallbacksKeepsPlaybackClearHandler(t *testing.T) {
	g := &GatewayClient{}
	called := 0
	g.SetPlaybackClearHandler(func() { called++ })
	// 既有 SetCallbacks 重注四回调时，不得覆盖打断回调。
	g.SetCallbacks(nil, nil, nil, nil)

	g.dispatch(gatewayEvent("playback.clear"))
	if called != 1 {
		t.Fatalf("SetCallbacks 后打断回调仍应生效，实际 %d 次", called)
	}
}

// ★2026-09-10 字幕补线：每个 response 首个带 responseId 的 audio.delta 记一次
// 回执状态（发送 playback.started）；同 response 的后续块与无 id 事件不重发。
// send 在无连接时静默（与 voice.ready 分支同约束），此处锁形状态迁移。
func TestGatewayPlaybackStartedReceipt(t *testing.T) {
	g := &GatewayClient{}
	ev := gatewayEvent("audio.delta")

	// 无 responseId：不记回执。
	g.dispatch(ev)
	if g.lastPlaybackReceipt != "" {
		t.Fatalf("无 responseId 不应记回执，实际 %q", g.lastPlaybackReceipt)
	}

	ev.ResponseId = "resp-a"
	g.dispatch(ev)
	if g.lastPlaybackReceipt != "resp-a" {
		t.Fatalf("首个带 responseId 的 audio.delta 应记回执，实际 %q", g.lastPlaybackReceipt)
	}

	// 同一 response 的后续块：不重复记。
	g.dispatch(ev)
	if g.lastPlaybackReceipt != "resp-a" {
		t.Fatalf("同 response 后续块不应重发回执，实际 %q", g.lastPlaybackReceipt)
	}

	// 新 response：重新回执。
	ev2 := gatewayEvent("audio.delta")
	ev2.ResponseId = "resp-b"
	g.dispatch(ev2)
	if g.lastPlaybackReceipt != "resp-b" {
		t.Fatalf("新 response 应重新回执，实际 %q", g.lastPlaybackReceipt)
	}
}
