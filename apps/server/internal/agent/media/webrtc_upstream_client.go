// WebRTC 上行客户端：把手机 WebRTC 音频（opus RTP）转发到 qwen-audio-agent
// 的 WebRTC 入口（POST /webrtc/sdp 交换 SDP）。全程 WebRTC 不转码，
// 替代 WS GatewayClient，避免 WS 长连接断连问题。
//
// 配置：AGENT_WEBRTC_URL=http://127.0.0.1:3101（qwen-audio-agent 的 HTTP 基址）
//       未配置时回退到现有 GatewayClient（WS）。
package media

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v3"
)

// WebRTCUpstreamClient 是连到 qwen-audio-agent WebRTC 入口的上行客户端。
type WebRTCUpstreamClient struct {
	mu      sync.Mutex
	baseURL string
	pc      *webrtc.PeerConnection
	outTrack *webrtc.TrackLocalStaticRTP
	closed   bool
	// ★重连互斥：断开常触发多个 OnConnectionStateChange（disconnected 后紧跟
	//   closed，且 reconnect 自身 pc.Close() 也会再触发一次），每个都会
	//   go c.reconnect() → 并发多个重连 goroutine，各自 POST /webrtc/sdp →
	//   qwen 会话洪水（一次掉线放大成十几条 WebRTC 连接）。reconnecting 保证
	//   同一时刻只有一条重连在跑，其余直接返回。
	reconnecting bool

	seq          uint16 // RTP 序号（转发时重新编号）
	ts           uint32 // RTP 时间戳
	forwardCount int    // 已转发帧计数（调试）

	// onReply 接收 qwen-audio-agent 的回复音频（opus RTP payload），
	// 由 session 绑定到手机播放（PlayFrame）。
	onReply func(payload []byte)

	// onTranscript 接收模型回复文字（经 DataChannel），由 session 绑定到手机字幕。
	onTranscript func(text string)
}

// SetReplyHandler 设置回复音频回调（AI 回复 → 手机）。
func (c *WebRTCUpstreamClient) SetReplyHandler(h func(payload []byte)) {
	c.mu.Lock()
	c.onReply = h
	c.mu.Unlock()
}

// SetTranscriptHandler 设置回复文字回调（AI 回复字幕 → 手机）。
func (c *WebRTCUpstreamClient) SetTranscriptHandler(h func(text string)) {
	c.mu.Lock()
	c.onTranscript = h
	c.mu.Unlock()
}

// NewWebRTCUpstreamClient 构造上行客户端（懒连接：不在此建连）。
// ★qwen-audio-agent 网关只保有一个活跃会话。若 media-agent 启动即建连并空闲
//   占用，真机来电或其他客户端连入会互踢——双方 3s 重连永远打架（07:58 实测
//   日志证实：每 ~14s 一轮互踢风暴，回复音频全被冲掉）。改为 HandleInit 时
//   EnsureConnected、HandleHangup 时 Close 释放网关会话。
func NewWebRTCUpstreamClient() *WebRTCUpstreamClient {
	baseURL := os.Getenv("AGENT_WEBRTC_URL")
	if baseURL == "" {
		return nil
	}
	return &WebRTCUpstreamClient{baseURL: baseURL, seq: uint16(time.Now().UnixNano() & 0xffff)}
}

// EnsureConnected 确保上行连接可用（HandleInit 会话开始时调用）。
// 已连接或正在重连时为 no-op；之前被 Close（通话结束）过的客户端允许重新建连。
func (c *WebRTCUpstreamClient) EnsureConnected() {
	c.mu.Lock()
	if c.baseURL == "" || c.pc != nil {
		c.mu.Unlock()
		return
	}
	c.closed = false
	base := c.baseURL
	c.mu.Unlock()
	go c.reconnect(base)
}

// Connected 返回当前是否有可用上行连接（冒烟工具轮询用）。
func (c *WebRTCUpstreamClient) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.pc != nil && !c.closed
}

func (c *WebRTCUpstreamClient) connect(baseURL string) error {
	// ★确保单连接：重连前彻底关闭旧连接（避免 qwen 侧累积多个会话）。
	c.mu.Lock()
	if c.pc != nil {
		_ = c.pc.Close()
		c.pc = nil
	}
	c.outTrack = nil
	c.mu.Unlock()

	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{{URLs: []string{"stun:stun.l.google.com:19302"}}},
	})
	if err != nil {
		return fmt.Errorf("NewPeerConnection: %w", err)
	}
	outTrack, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2},
		"audio", "myphone-upstream-audio",
	)
	if err != nil {
		pc.Close()
		return fmt.Errorf("NewTrackLocalStaticRTP: %w", err)
	}
	if _, err := pc.AddTrack(outTrack); err != nil {
		pc.Close()
		return fmt.Errorf("AddTrack: %w", err)
	}
	// ★DataChannel（offer 端创建）：qwen-audio-agent 用它回传模型回复文字。
	//   用 CreateDataChannel 返回的 dc.OnMessage 接收（不是 pc.OnDataChannel，
	//   那是给 offer 端接收 answer 端额外通道用的）。
	replyDC, err := pc.CreateDataChannel("reply-text", nil)
	if err != nil {
		pc.Close()
		return fmt.Errorf("CreateDataChannel: %w", err)
	}
	// ★字幕累积：网关按 response.text.delta 逐片发 transcript（每片单独发会碎字，
	//   且每片都触发一次聊天回流刷屏）。transcript_done 表示整句结束——与
	//   DashScope 路径语义一致：delta 只累积，done 合并发一次完整文本。
	//   兜底：打断等异常导致 done 丢失时，5s 无增量即 flush 残句，
	//   避免残句并入下一句（timer 回调与 DC 读回调不同 goroutine，需加锁）。
	var (
		textMu   sync.Mutex
		textBuf  string
		flushTmr *time.Timer
	)
	flushText := func() {
		textMu.Lock()
		full := textBuf
		textBuf = ""
		textMu.Unlock()
		if full == "" {
			return
		}
		// MiniCPM-o 偶发泄漏推理标签（</think>），字幕/回流前剥掉。
		full = strings.TrimSpace(strings.TrimPrefix(full, "</think>"))
		log.Printf("[WEBRTC-UP] transcript final: %s", full)
		c.mu.Lock()
		onTranscript := c.onTranscript
		c.mu.Unlock()
		if onTranscript != nil {
			onTranscript(full)
		}
	}
	scheduleFlush := func() {
		textMu.Lock()
		if flushTmr != nil {
			flushTmr.Stop()
		}
		flushTmr = time.AfterFunc(5*time.Second, func() { flushText() })
		textMu.Unlock()
	}
	replyDC.OnMessage(func(msg webrtc.DataChannelMessage) {
		var ev struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if err := json.Unmarshal(msg.Data, &ev); err != nil {
			return
		}
		switch ev.Type {
		case "transcript":
			if ev.Text == "" {
				return
			}
			log.Printf("[WEBRTC-UP] transcript delta: %s", ev.Text)
			textMu.Lock()
			textBuf += ev.Text
			textMu.Unlock()
			scheduleFlush()
		case "transcript_done":
			flushText()
		}
	})

	// ★下行：接收 qwen-audio-agent 发来的回复音频（opus RTP），转发给手机。
	pc.OnTrack(func(tr *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if tr.Kind() != webrtc.RTPCodecTypeAudio {
			return
		}
		log.Printf("[WEBRTC-UP] reply track received")
		go func() {
			replyCount := 0
			for {
				pkt, _, err := tr.ReadRTP()
				if err != nil {
					break
				}
				if len(pkt.Payload) == 0 {
					continue
				}
				// ★日志H：收到下行回复音频（每 100 帧打一次）。
				replyCount++
				if replyCount%100 == 0 || replyCount == 1 {
					log.Printf("[WEBRTC-UP] reply frame %d received: %dB", replyCount, len(pkt.Payload))
				}
				c.mu.Lock()
				onReply := c.onReply
				c.mu.Unlock()
				if onReply != nil {
					onReply(pkt.Payload)
				}
			}
		}()
	})

	// 发 offer → POST /webrtc/sdp → 收 answer。
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		pc.Close()
		return fmt.Errorf("CreateOffer: %w", err)
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		pc.Close()
		return fmt.Errorf("SetLocalDescription: %w", err)
	}

	ld := pc.LocalDescription()
	offerJSON, _ := json.Marshal(map[string]string{
		"sdp": mustJSON(map[string]string{"sdp": ld.SDP, "type": "offer"}),
	})
	resp, err := http.Post(baseURL+"/webrtc/sdp", "application/json", bytes.NewReader(offerJSON))
	if err != nil {
		pc.Close()
		return fmt.Errorf("POST /webrtc/sdp: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		pc.Close()
		return fmt.Errorf("/webrtc/sdp status=%d: %s", resp.StatusCode, string(respBody))
	}
	var ans struct {
		Answer struct {
			SDP string `json:"sdp"`
		} `json:"answer"`
	}
	if err := json.Unmarshal(respBody, &ans); err != nil {
		pc.Close()
		return fmt.Errorf("parse answer: %w", err)
	}
	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer, SDP: ans.Answer.SDP,
	}); err != nil {
		pc.Close()
		return fmt.Errorf("SetRemoteDescription: %w", err)
	}

	c.mu.Lock()
	c.pc = pc
	c.outTrack = outTrack
	c.closed = false
	c.mu.Unlock()
	log.Printf("[WEBRTC-UP] connected to %s", baseURL)

	// ★自动重连：检测 PeerConnection 断开，重连 qwen-audio-agent。
	//   服务重启后无需手动重启 media-agent。
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("[WEBRTC-UP] connection state: %s", state)
		if state == webrtc.PeerConnectionStateDisconnected ||
			state == webrtc.PeerConnectionStateFailed ||
			state == webrtc.PeerConnectionStateClosed {
			log.Printf("[WEBRTC-UP] connection lost, reconnecting...")
			go c.reconnect(baseURL)
		}
	})
	return nil
}

// reconnect 断开后重连（先试后等：第 1 次立即尝试，重试间隔 3 秒，最多 5 次）。
// 通话结束（closed=true）后不再重连，避免空闲占用网关单会话。
func (c *WebRTCUpstreamClient) reconnect(baseURL string) {
	c.mu.Lock()
	if c.closed || c.reconnecting {
		c.mu.Unlock()
		return
	}
	c.reconnecting = true
	c.mu.Unlock()
	// 重连结束（成功/耗尽）后释放互斥，允许下次断开重连。
	defer func() {
		c.mu.Lock()
		c.reconnecting = false
		c.mu.Unlock()
	}()
	// 断开旧连接。
	c.mu.Lock()
	if c.pc != nil {
		_ = c.pc.Close()
		c.pc = nil
	}
	c.outTrack = nil
	c.mu.Unlock()

	for attempt := 1; attempt <= 5; attempt++ {
		if attempt > 1 {
			time.Sleep(3 * time.Second)
			log.Printf("[WEBRTC-UP] reconnect attempt %d", attempt)
		}
		if err := c.connect(baseURL); err == nil {
			return
		}
	}
	log.Printf("[WEBRTC-UP] reconnect failed after 5 attempts")
}

// ForwardOpus 把一帧手机 opus RTP payload 转发到 qwen-audio-agent。
func (c *WebRTCUpstreamClient) ForwardOpus(payload []byte) {
	c.mu.Lock()
	if c.closed || c.outTrack == nil {
		c.mu.Unlock()
		return
	}
	out := c.outTrack
	c.seq++
	c.ts += 960 // 48kHz / 20ms
	pkt := &rtp.Packet{
		Header: rtp.Header{
			Version:        2,
			PayloadType:    111, // opus 动态 PT
			SequenceNumber: c.seq,
			Timestamp:      c.ts,
			SSRC:           0x55AA55AA,
		},
		Payload: payload,
	}
	c.mu.Unlock()
	if err := out.WriteRTP(pkt); err != nil {
		log.Printf("[WEBRTC-UP] WriteRTP failed: %v", err)
		return
	}
	// ★调试：确认转发发生（每 100 帧打一次）。
	c.mu.Lock()
	c.forwardCount++
	if c.forwardCount%100 == 0 {
		log.Printf("[WEBRTC-UP] forwarded %d opus frames", c.forwardCount)
	}
	c.mu.Unlock()
}

// Close 关闭连接。
func (c *WebRTCUpstreamClient) Close() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	pc := c.pc
	c.pc = nil
	c.outTrack = nil
	c.mu.Unlock()
	if pc != nil {
		_ = pc.Close()
	}
}

func mustJSON(v interface{}) string {
	b, _ := json.Marshal(v)
	return string(b)
}
