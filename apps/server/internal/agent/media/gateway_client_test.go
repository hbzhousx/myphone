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
