// RealtimeClient 单测：mock vllm-omni Realtime 服务端（httptest + gorilla
// Upgrader），验证协议序列与重连，不需要 libopus。
package media

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type transcriptEvent struct {
	text  string
	final bool
}

func pcm16ToLEBytes(pcm []int16) []byte {
	buf := make([]byte, len(pcm)*2)
	for i, s := range pcm {
		buf[i*2] = byte(s)
		buf[i*2+1] = byte(s >> 8)
	}
	return buf
}

func leBytesToPCM16(b []byte) []int16 {
	pcm := make([]int16, len(b)/2)
	for i := range pcm {
		pcm[i] = int16(b[i*2]) | int16(b[i*2+1])<<8
	}
	return pcm
}

func wsURL(srv *httptest.Server) string {
	return "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/realtime"
}

// TestRealtimeClientProtocolSequence 全协议序列：首条 session.update 形状 →
// session.created→onVoiceReady → 上行 append（200ms 块、累计 audio_end_ms）→
// 下行 audio.delta / listen / transcript.delta / done。
func TestRealtimeClientProtocolSequence(t *testing.T) {
	upgrader := websocket.Upgrader{}
	sessionUpdateCh := make(chan map[string]interface{}, 4)
	appendCh := make(chan map[string]interface{}, 8)
	pushCh := make(chan []byte, 8) // 测试 → 服务端：要推给客户端的事件

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("duplex") != "1" {
			t.Errorf("missing duplex=1 query, got %q", r.URL.RawQuery)
			return
		}
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		// 首条必须是 session.update。
		_, msg, err := conn.ReadMessage()
		if err != nil {
			t.Errorf("read first msg: %v", err)
			return
		}
		var env map[string]interface{}
		if json.Unmarshal(msg, &env) != nil || env["type"] != "session.update" {
			t.Errorf("first msg not session.update: %s", msg)
			return
		}
		sessionUpdateCh <- env
		// 收 append，同时转发测试推的事件。
		go func() {
			for {
				_, msg, err := conn.ReadMessage()
				if err != nil {
					return
				}
				var m map[string]interface{}
				if json.Unmarshal(msg, &m) == nil && m["type"] == "input_audio_buffer.append" {
					appendCh <- m
				}
			}
		}()
		for ev := range pushCh {
			if err := conn.WriteMessage(websocket.TextMessage, ev); err != nil {
				return
			}
		}
	}))
	defer srv.Close()
	defer close(pushCh)

	rt := NewRealtimeClient(RealtimeConfig{
		URL:          wsURL(srv),
		Model:        "openbmb/MiniCPM-o-4_5",
		Instructions: "你是哪吒",
	})
	defer rt.Close()

	voiceReadyCh := make(chan struct{}, 4)
	speechStartCh := make(chan struct{}, 4)
	audioCh := make(chan []int16, 8)
	transcriptCh := make(chan transcriptEvent, 8)
	rt.SetCallbacks(
		func(text string, final bool) { transcriptCh <- transcriptEvent{text, final} },
		func(pcm []int16) { audioCh <- pcm },
		func() { speechStartCh <- struct{}{} },
		func() { voiceReadyCh <- struct{}{} },
		func(err error) { t.Logf("onError: %v", err) },
	)

	// --- session.update 形状（照抄 demo configure() 实测形状）---
	var env map[string]interface{}
	select {
	case env = <-sessionUpdateCh:
	case <-time.After(2 * time.Second):
		t.Fatal("no session.update")
	}
	sess, ok := env["session"].(map[string]interface{})
	if !ok {
		t.Fatalf("session not an object: %v", env)
	}
	if sess["model"] != "openbmb/MiniCPM-o-4_5" {
		t.Errorf("model = %v", sess["model"])
	}
	if v, ok := sess["turn_detection"]; !ok || v != nil {
		t.Errorf("turn_detection must be explicit null, got %v (present=%v)", v, ok)
	}
	if sess["overlap_policy"] != "listen_only" {
		t.Errorf("overlap_policy = %v", sess["overlap_policy"])
	}
	if sess["playback_commit_policy"] != "ack_only" {
		t.Errorf("playback_commit_policy = %v", sess["playback_commit_policy"])
	}
	if sess["instructions"] != "你是哪吒" {
		t.Errorf("instructions = %v", sess["instructions"])
	}
	if sess["temperature"] != 0.8 {
		t.Errorf("temperature = %v", sess["temperature"])
	}
	mods, ok := sess["modalities"].([]interface{})
	if !ok || len(mods) != 2 || mods[0] != "audio" || mods[1] != "text" {
		t.Errorf("modalities = %v", sess["modalities"])
	}
	eb, ok := sess["extra_body"].(map[string]interface{})
	if !ok {
		t.Fatalf("extra_body not an object: %v", sess)
	}
	if eb["auto_response"] != true || eb["minicpmo45_native_duplex"] != true {
		t.Errorf("extra_body flags = %v", eb)
	}
	if eb["force_listen_count"] != float64(0) {
		t.Errorf("force_listen_count = %v", eb["force_listen_count"])
	}

	// --- session.created → onVoiceReady ---
	pushCh <- []byte(`{"type":"session.created"}`)
	select {
	case <-voiceReadyCh:
	case <-time.After(2 * time.Second):
		t.Fatal("no onVoiceReady on session.created")
	}

	// --- 上行：10×320 样本累积成一帧 200ms append；再 10 帧验证累计 audio_end_ms ---
	frame := make([]int16, 320)
	for i := range frame {
		frame[i] = int16(i % 251)
	}
	for k := 0; k < 10; k++ {
		rt.AppendPCM16k(frame)
	}
	assertAppend := func(wantEndMs float64) {
		t.Helper()
		var ap map[string]interface{}
		select {
		case ap = <-appendCh:
		case <-time.After(2 * time.Second):
			t.Fatal("no input_audio_buffer.append")
		}
		raw, err := base64.StdEncoding.DecodeString(ap["audio"].(string))
		if err != nil {
			t.Fatalf("append audio b64: %v", err)
		}
		if len(raw) != 6400 {
			t.Errorf("append bytes = %d, want 6400", len(raw))
		}
		pcm := leBytesToPCM16(raw)
		if len(pcm) > 6 && (pcm[0] != frame[0] || pcm[5] != frame[5] || pcm[319] != frame[319]) {
			t.Errorf("append pcm mismatch: %v vs %v", pcm[:6], frame[:6])
		}
		if ap["sample_rate_hz"] != float64(16000) || ap["duration_ms"] != float64(200) {
			t.Errorf("append sr/dur = %v/%v", ap["sample_rate_hz"], ap["duration_ms"])
		}
		if ap["audio_end_ms"] != wantEndMs {
			t.Errorf("audio_end_ms = %v, want %v (must be cumulative)", ap["audio_end_ms"], wantEndMs)
		}
	}
	assertAppend(200)
	for k := 0; k < 10; k++ {
		rt.AppendPCM16k(frame)
	}
	assertAppend(400)

	// --- 下行：audio.delta → listen → transcript.delta/done ---
	down := []int16{1234, -5678, 32767, -32768}
	payload, _ := json.Marshal(map[string]interface{}{
		"type":  "response.audio.delta",
		"delta": base64.StdEncoding.EncodeToString(pcm16ToLEBytes(down)),
	})
	pushCh <- payload
	select {
	case got := <-audioCh:
		if len(got) != len(down) {
			t.Fatalf("onAudioDelta len = %d, want %d", len(got), len(down))
		}
		for i := range down {
			if got[i] != down[i] {
				t.Errorf("onAudioDelta[%d] = %d, want %d", i, got[i], down[i])
			}
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no onAudioDelta")
	}

	pushCh <- []byte(`{"type":"response.listen"}`)
	select {
	case <-speechStartCh:
	case <-time.After(2 * time.Second):
		t.Fatal("no onSpeechStart on response.listen")
	}

	pushCh <- []byte(`{"type":"response.audio_transcript.delta","delta":"你好"}`)
	select {
	case ev := <-transcriptCh:
		if ev.text != "你好" || ev.final {
			t.Errorf("delta transcript = %+v", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no transcript delta")
	}

	pushCh <- []byte(`{"type":"response.audio_transcript.done","transcript":"你好世界"}`)
	select {
	case ev := <-transcriptCh:
		if ev.text != "你好世界" || !ev.final {
			t.Errorf("done transcript = %+v", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no transcript done")
	}
}

// TestRealtimeClientReconnect 服务端断开 → 客户端 ~3s 后重拨并重发 session.update。
func TestRealtimeClientReconnect(t *testing.T) {
	upgrader := websocket.Upgrader{}
	sessionCount := make(chan struct{}, 4)
	var mu sync.Mutex
	var conns []*websocket.Conn

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		mu.Lock()
		conns = append(conns, conn)
		mu.Unlock()
		_, msg, err := conn.ReadMessage()
		if err != nil {
			return
		}
		var env map[string]interface{}
		if json.Unmarshal(msg, &env) != nil || env["type"] != "session.update" {
			t.Errorf("expected session.update, got: %s", msg)
			return
		}
		sessionCount <- struct{}{}
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}))
	defer srv.Close()

	rt := NewRealtimeClient(RealtimeConfig{URL: wsURL(srv)})
	defer rt.Close()

	select {
	case <-sessionCount:
	case <-time.After(2 * time.Second):
		t.Fatal("no initial session.update")
	}

	// 服务端主动断开第一条连接 → 客户端应重拨并重发 session.update。
	mu.Lock()
	first := conns[0]
	mu.Unlock()
	_ = first.Close()

	select {
	case <-sessionCount:
	case <-time.After(10 * time.Second):
		t.Fatal("no session.update after reconnect")
	}
}
