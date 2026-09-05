// Package media 实现 v1.50 AI 语音通话的媒体端点（Pion WebRTC）。
//
// ★部署硬约束：服务器以 CGO_ENABLED=0 交叉编译，媒体端点**不依赖本地 Opus
// 编解码**（libopus/cgo）。因此本包只做 RTP 转发：
//   - 入站（用户语音）：OnTrack 收到 Opus RTP → payload 直转 [ASR] provider；
//   - 出站（TTS）：[TTS] provider 返回预编码 Opus 帧 → [TrackLocalStaticRTP] 直写。
//
// 编解码责任交给 provider 实现（外部 ASR/TTS 服务），本包零编解码。
package media

import (
	"log"
	"encoding/base64"
	"encoding/json"
	"sync"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v3"
)

// Signaling 是媒体端点向 myphone-server 回推 a2c 信令的接口（由 bridge_server 实现）。
// 每个 a2c 信封都必须带 user_id（回推目标）与 type。
type Signaling interface {
	SendToServer(userID string, typ string, payload map[string]interface{})
}

// Session 表示一个用户与媒体端点之间的 AI 语音会话。
type Session struct {
	userID    string
	sessionID string
	pc        *webrtc.PeerConnection
	outTrack  *webrtc.TrackLocalStaticRTP
	sig       Signaling
	pipeline  *Pipeline

	// RTP 出站状态（WriteRTP 需自行递增 seq/timestamp/ssrc）。
	seq            uint16
	ts             uint32
	ssrc           uint32
	lastFrameTime  time.Time // 上一帧发送时刻(限速用)

	mu     sync.Mutex
	closed bool

	// ★异步播放队列:play 回调只入队立即返回(不阻塞 readLoop),
	//   后台 goroutine 按 20ms 节奏发送。打断时 ClearQueue 停止播放。
	playQueue  [][]byte
	playSignal chan struct{}
	playCount  int // 已入队播放帧计数（调试）

	// ★字幕序号（每会话单调递增）。此前用 UnixMilli%100000，每 100s 回绕一次，
	//   手机端 seq 去重会丢弃之后所有字幕（问题③"字幕不全"的另一半根因）。
	transcriptSeq int
}

// frameInterval 是 Opus 单帧时长(20ms),PlayFrame 限速按此发送。
const frameInterval = 20 * time.Millisecond

// SendToServer 直通 Signaling（pipeline 回 chatMessage 用）。
func (s *Session) SendToServer(userID, typ string, payload map[string]interface{}) {
	s.sig.SendToServer(userID, typ, payload)
}

// send 带 session_id 回推一条 a2c。
func (s *Session) send(typ string, payload map[string]interface{}) {
	if payload == nil {
		payload = map[string]interface{}{}
	}
	payload["session_id"] = s.sessionID
	s.sig.SendToServer(s.userID, typ, payload)
}

// nextTranscriptSeq 每会话单调递增的字幕序号。替代 UnixMilli%100000（每 100s
// 回绕，手机端 seq 去重会丢弃之后所有字幕）。
func (s *Session) nextTranscriptSeq() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.transcriptSeq++
	return s.transcriptSeq
}

// SendReady 通知客户端状态机。
func (s *Session) SendReady(state, reason string) {
	p := map[string]interface{}{"state": state}
	if reason != "" {
		p["reason"] = reason
	}
	s.send("agentReady", p)
}

// SendTranscript 下发一条字幕。
func (s *Session) SendTranscript(seq int, who, text string, isFinal bool) {
	s.send("agentTranscript", map[string]interface{}{
		"seq":      seq,
		"who":      who,
		"text":     text,
		"is_final": isFinal,
	})
}

// SendHangup 通知客户端会话结束。
func (s *Session) SendHangup() {
	s.send("agentHangup", map[string]interface{}{})
}

// PlayFrame 把一帧 Opus 入队,由后台 goroutine 按 20ms 节奏发送。
// ★不阻塞调用方(readLoop):打断时 DashScope 消息能及时读到。
func (s *Session) PlayFrame(frame []byte) {
	s.mu.Lock()
	if s.closed || s.outTrack == nil {
		s.mu.Unlock()
		return
	}
	s.playQueue = append(s.playQueue, frame)
	// ★日志I：AI 回复音频进入播放队列（每 100 帧打一次）。
	s.playCount++
	if s.playCount%100 == 0 || s.playCount == 1 {
		log.Printf("[MEDIA] %s PlayFrame %d enqueued: %dB", s.userID, s.playCount, len(frame))
	}
	s.mu.Unlock()
	select {
	case s.playSignal <- struct{}{}:
	default:
	}
}

// startPlayback 启动后台发送 goroutine(HandleInit 建会话时调用)。
// 按 20ms/帧从队列取帧发送;队列空则等待。
func (s *Session) startPlayback() {
	go func() {
		for {
			s.mu.Lock()
			if s.closed {
				s.mu.Unlock()
				return
			}
			var frame []byte
			if len(s.playQueue) > 0 {
				frame = s.playQueue[0]
				s.playQueue = s.playQueue[1:]
			}
			s.mu.Unlock()
			if frame == nil {
				// 队列空,等信号。
				select {
				case <-s.playSignal:
					continue
				case <-time.After(frameInterval):
					continue
				}
			}
			// 限速:距上一帧 20ms 发送。
			if !s.lastFrameTime.IsZero() {
				elapsed := time.Since(s.lastFrameTime)
				if elapsed < frameInterval {
					time.Sleep(frameInterval - elapsed)
				}
			}
			s.lastFrameTime = time.Now()
			s.seq++
			s.ts += 960 // 48kHz / 20ms = 960 samples/frame
			pkt := &rtp.Packet{
				Header: rtp.Header{
					Version:        2,
					PayloadType:    111, // opus 静态 PT(与客户端协商一致)
					SequenceNumber: s.seq,
					Timestamp:      s.ts,
					SSRC:           s.ssrc,
					Marker:         false,
				},
				Payload: frame,
			}
			if err := s.outTrack.WriteRTP(pkt); err != nil {
				log.Printf("[MEDIA] WriteRTP failed: %v", err)
			}
		}
	}()
}

// ClearPlayQueue 清空待播帧(打断时调用,立即停止当前回复)。
func (s *Session) ClearPlayQueue() {
	s.mu.Lock()
	s.playQueue = nil
	s.mu.Unlock()
	// 唤醒发送 goroutine(它醒来发现队列空则继续等)。
	select {
	case s.playSignal <- struct{}{}:
	default:
	}
}

// Close 释放 PeerConnection 与管线。
// bindDash 把 DashScope 直连客户端的回调接到本会话：
// 回复音频→PlayFrame回手机；识别/回复文本→字幕；完整回复→聊天回流。
func (s *Session) bindDash(d *DashScopeClient) {
	log.Printf("[MEDIA] %s bindDash to session %s", s.userID, s.sessionID)
	d.SetCallbacks(
		func(frame []byte) {
			s.PlayFrame(frame)
		},
		func(who, text string) {
			seq := s.nextTranscriptSeq()
			s.SendTranscript(seq, who, text, true)
		},
		// ★用户说话状态：麦克风动态图标（speech_started/stopped）。
		//   开始说话(插话)时:①清空播放队列(立即停当前回复声音) ②发 response.cancel
		//   给 DashScope(取消旧回复生成,避免旧上下文残留导致话题偏)。
		func(speaking bool) {
			if speaking {
				s.ClearPlayQueue()
				d.Interrupt()
			}
			s.send("agentSpeech", map[string]interface{}{"speaking": speaking})
		},
		func(text string) {
			// 聊天历史回流（bot 明文 chatMessage）。
			plain := map[string]interface{}{"kind": "agent", "body": text}
			plainJSON, _ := json.Marshal(plain)
			payload := map[string]interface{}{
				"message_id": "agent-" + nowStr(time.Now().UnixMilli()),
				"ciphertext": base64.StdEncoding.EncodeToString(plainJSON),
				"counter":    0,
				"plaintext":  true,
			}
			s.SendToServer(s.userID, "chatMessage", payload)
		},
	)
}

func (s *Session) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.mu.Unlock()
	if s.pipeline != nil {
		s.pipeline.Close()
	}
	if s.pc != nil {
		_ = s.pc.Close()
	}
}

// Manager 维护用户 → 会话映射（一个用户同时最多一个 AI 会话）。
type Manager struct {
	sig        Signaling
	asr        ASR
	tts        TTS
	agent      AgentText
	iceServers []webrtc.ICEServer

	// gateway 是可选的 qwen-audio-agent 语音引擎客户端。配置了 AGENT_GATEWAY_URL
	// 时，入站语音/出站语音/字幕/回流全部经 Gateway；否则回退 asr/tts/agent。
	gateway *GatewayClient
	dash   *DashScopeClient
	codec  *OpusCodec

	// ★WebRTC 上行：连 qwen-audio-agent 的 WebRTC 入口，手机 opus 原样转发
	//   （全程 WebRTC 不转码，替代 WS Gateway 的长连接断连问题）。
	webrtcUp *WebRTCUpstreamClient

	// vllm 是可选的 vllm-omni Realtime 直连客户端（AGENT_VLLMOMNI_URL，
	// 绕过 qwen-audio-agent 网关）。
	vllm *RealtimeClient

	// replySink 是 WebRTC 下行（AI 回复音频→手机）的当前接收点。
	// HandleInit 时指向新 session 的 PlayFrame；无活跃会话时为 nil。
	replySink func(payload []byte)

	// transcriptSink 是 WebRTC 下行（AI 回复文字→手机字幕）的当前接收点。
	// transcriptSink：字幕下发（★2026-09-03 官方语义）。final=true 整轮终稿
	//   （字幕+聊天回流），final=false 流式增量（仅字幕，不写聊天记录）。
	transcriptSink func(text string, final bool)

	// playbackClear 是打断时清当前会话播放队列的接收点（与 replySink 同一套
	// "当前会话接收点"机制；无活跃会话时为 nil）。
	playbackClear func()

	mu       sync.Mutex
	sessions map[string]*Session
}

func NewManager(sig Signaling, asr ASR, tts TTS, agent AgentText, iceServers []webrtc.ICEServer) *Manager {
	return &Manager{
		sig:        sig,
		asr:        asr,
		tts:        tts,
		agent:      agent,
		iceServers: iceServers,
		sessions:   make(map[string]*Session),
	}
}

// SetSignaling 注入回推实现（manager↔bridge 互相引用，用 setter 解开初始化顺序）。
func (m *Manager) SetSignaling(sig Signaling) {
	m.mu.Lock()
	m.sig = sig
	m.mu.Unlock()
}

// SetGateway 注入 qwen-audio-agent 语音引擎客户端（有则优先走 Gateway）。
func (m *Manager) SetGateway(gw *GatewayClient, codec *OpusCodec) {
	m.mu.Lock()
	m.gateway = gw
	m.codec = codec
	m.mu.Unlock()
}

// SetWebRTCUpstream 注入 WebRTC 上行客户端（连 qwen-audio-agent 的 WebRTC 入口）。
// 启用时手机 opus 原样转发给它（全程 WebRTC），优先于 WS Gateway/DashScope。
func (m *Manager) SetWebRTCUpstream(w *WebRTCUpstreamClient) {
	m.mu.Lock()
	m.webrtcUp = w
	m.mu.Unlock()
}

// SetVllmOmni 注入 vllm-omni Realtime 直连客户端（AGENT_VLLMOMNI_URL）。
func (m *Manager) SetVllmOmni(rt *RealtimeClient, codec *OpusCodec) {
	m.mu.Lock()
	m.vllm = rt
	m.codec = codec
	m.mu.Unlock()
}

// ReplySink 是 WebRTC 下行的接收点：qwen-audio-agent 的回复音频 → 当前活跃
// 会话的手机播放。作为 SetReplyHandler 的回调。
func (m *Manager) ReplySink(payload []byte) {
	m.mu.Lock()
	sink := m.replySink
	m.mu.Unlock()
	if sink != nil {
		sink(payload)
	}
}

// TranscriptSink 是 WebRTC 下行文字接收点：模型回复整轮终稿（fork
// response.done 全文）→ 当前活跃会话的手机。字幕 + 聊天历史回流。
// 作为 SetTranscriptHandler 的回调。
func (m *Manager) TranscriptSink(text string) {
	m.mu.Lock()
	sink := m.transcriptSink
	m.mu.Unlock()
	if sink != nil {
		sink(text, true)
	}
}

// TranscriptDelta 转发流式字幕增量（官方语义：客户端逐 delta 更新字幕）。
// 只更新手机字幕，不写聊天记录。
func (m *Manager) TranscriptDelta(text string) {
	m.mu.Lock()
	sink := m.transcriptSink
	m.mu.Unlock()
	if sink != nil {
		sink(text, false)
	}
}

// ClearPlayback 清当前会话的播放队列（barge-in 时由 RealtimeClient 的
// onSpeechStart 回调调用）。与 replySink 同一套"当前会话接收点"机制，
// 无活跃会话时静默。
func (m *Manager) ClearPlayback() {
	m.mu.Lock()
	fn := m.playbackClear
	m.mu.Unlock()
	if fn != nil {
		fn()
	}
}

// SetDashScope 注入 DashScope 直连客户端（方向 B，优先于 Gateway）。
func (m *Manager) SetDashScope(d *DashScopeClient, codec *OpusCodec) {
	m.mu.Lock()
	m.dash = d
	m.codec = codec
	m.mu.Unlock()
}

// HandleInit 处理 agentInit（新会话，替换旧会话）。
func (m *Manager) HandleInit(userID, sessionID string) {
	m.mu.Lock()
	if old := m.sessions[userID]; old != nil {
		old.Close()
		delete(m.sessions, userID)
	}
	// 强制 relay-only：手机(公网)与 media-agent(阿里云)直连基本不可能，
	// 必须走 TURN 中继；与客户端 iceTransportPolicy=relay 保持一致，
	// 避免"手机 all 直连失败/中继"与"Pion 默认 all"策略不匹配导致 ICE failed。
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers:         m.iceServers,
		ICETransportPolicy: webrtc.ICETransportPolicyRelay,
	})
	if err != nil {
		m.mu.Unlock()
		log.Printf("[MEDIA] NewPeerConnection failed: %v", err)
		return
	}
	outTrack, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2},
		"audio", "myphone-agent-audio",
	)
	if err != nil {
		m.mu.Unlock()
		_ = pc.Close()
		log.Printf("[MEDIA] NewTrackLocalStaticRTP failed: %v", err)
		return
	}
	if _, err := pc.AddTrack(outTrack); err != nil {
		m.mu.Unlock()
		_ = pc.Close()
		log.Printf("[MEDIA] AddTrack failed: %v", err)
		return
	}

	// 随机 SSRC。
	ssrc := uint32(time.Now().UnixNano() & 0xffffffff)
	s := &Session{
		userID:     userID,
		sessionID:  sessionID,
		pc:         pc,
		outTrack:   outTrack,
		sig:        m.sig,
		ssrc:       ssrc,
		playSignal: make(chan struct{}, 8),
	}
	// 启动后台播放 goroutine(异步发送,不阻塞 readLoop,支持打断)。
	s.startPlayback()
	s.pipeline = NewPipeline(s, m.asr, m.tts, m.agent, userID)
	// 方向 B：把 DashScope 直连回调接到本会话（回复音频/字幕/聊天回流）。
	if m.dash != nil {
		s.bindDash(m.dash)
	}
	m.sessions[userID] = s
	// ★WebRTC 下行接收点：新会话建立后，AI 回复音频发给本会话播放。
	m.replySink = func(payload []byte) {
		s.PlayFrame(payload)
	}
	// ★WebRTC 下行文字：模型回复字幕 → 本会话的手机字幕。
	// ★2026-09-03 官方语义（minicpmo45.modelbest.cn /docs/zh/realtime-api/audio/）：
	//   客户端逐 delta 更新字幕。增量（final=false）只发字幕不写聊天记录；
	//   终稿（final=true，fork response.done 全文）发字幕 + 聊天历史回流，
	//   每轮恰好一条聊天消息（原实现每条字幕都回流会刷屏）。
	m.transcriptSink = func(text string, final bool) {
		if text == "" {
			return
		}
		seq := s.nextTranscriptSeq()
		s.SendTranscript(seq, "agent", text, final)
		if !final {
			return
		}
		// ★聊天历史回流（bot 明文 chatMessage）：让文字落到聊天记录。
		plain := map[string]interface{}{"kind": "agent", "body": text}
		plainJSON, _ := json.Marshal(plain)
		payload := map[string]interface{}{
			"message_id": "agent-" + nowStr(time.Now().UnixMilli()),
			"ciphertext": base64.StdEncoding.EncodeToString(plainJSON),
			"counter":    0,
			"plaintext":  true,
		}
		s.SendToServer(s.userID, "chatMessage", payload)
	}
	// ★barge-in 接收点：打断时清当前会话播放队列（与 replySink 同机制）。
	m.playbackClear = func() {
		s.ClearPlayQueue()
	}
	// ★懒连接：仅在有活跃 AI 通话时才连 qwen 网关（HandleHangup 时 Close 释放）。
	//   空闲占用会与真机来电互踢形成重连风暴（详见 webrtc_upstream_client.go 注释）。
	if m.webrtcUp != nil {
		m.webrtcUp.EnsureConnected()
	}
	// ★2026-09-03：WS Gateway 路径同样在通话开始重新 takeover——unmute 只在
	//   voice.ready 发一次会被探针/网页端夺权且无恢复（详见 GatewayClient.Activate）。
	if gw := m.gateway; gw != nil {
		gw.Activate()
	}

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			log.Printf("[MEDIA] %s ICE gathering complete", userID)
			return
		}
		j := c.ToJSON()
		log.Printf("[MEDIA] %s ICE candidate: %s", userID, j.Candidate)
		s.send("agentSignal", map[string]interface{}{
			"signal": map[string]interface{}{
				"type":             "ice",
				"candidate":        j.Candidate,
				"sdp_mid":          j.SDPMid,
				"sdp_m_line_index": j.SDPMLineIndex,
			},
		})
	})
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		log.Printf("[MEDIA] %s conn state: %s", userID, st.String())
		if st == webrtc.PeerConnectionStateFailed || st == webrtc.PeerConnectionStateClosed {
			m.HandleHangup(userID)
		}
	})
	pc.OnTrack(func(tr *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		// 入站用户语音：逐 RTP 包抽 Opus payload。
		log.Printf("[MEDIA] %s OnTrack fired (track=%s)", userID, tr.Kind())
		go func() {
			// ★埋点（2026-08-30 排障"模型听不懂"）：上行审计——RTP 序号缺口
			//   （丢包）+ 每 5s 包率/采样率（健康值：50 包/s、16000 采样/s）。
			var lastSeq uint16
			var haveSeq bool
			var auditStart time.Time
			var auditPkts int
			var auditSamples int
			for {
				pkt, _, err := tr.ReadRTP()
				if err != nil {
					log.Printf("[MEDIA] %s OnTrack read end: %v", userID, err)
					break
				}
				if len(pkt.Payload) == 0 {
					continue
				}
				now := time.Now()
				if auditStart.IsZero() {
					auditStart = now
				}
				if haveSeq {
					if gap := int(pkt.SequenceNumber) - int(lastSeq); gap > 1 && gap < 1000 {
						log.Printf("[MEDIA] %s RTP seq gap %d (lost ~%d pkts)", userID, gap, gap-1)
					}
				}
				lastSeq, haveSeq = pkt.SequenceNumber, true
				auditPkts++
				if now.Sub(auditStart) >= 5*time.Second {
					elapsed := now.Sub(auditStart).Seconds()
					log.Printf("[MEDIA] %s uplink audit: pkts=%d (%.1f/s) samples=%d (%.0f%% real-time)",
						userID, auditPkts, float64(auditPkts)/elapsed, auditSamples,
						100*float64(auditSamples)/elapsed/16000)
					auditStart, auditPkts, auditSamples = now, 0, 0
				}
				m.mu.Lock()
				wUp := m.webrtcUp
				gw := m.gateway
				dash := m.dash
				rt := m.vllm
				codec := m.codec
				m.mu.Unlock()
				// ★WebRTC 上行优先：手机 opus 原样转发给 qwen-audio-agent 的
				//   WebRTC 入口（全程 WebRTC 不转码），替代 WS Gateway 断连。
				if wUp != nil {
					wUp.ForwardOpus(pkt.Payload)
					continue
				}
				// vllm-omni 直连（AGENT_VLLMOMNI_URL）：优先于 DashScope/Gateway。
				if rt != nil && codec != nil {
					pcm16, err := codec.DecodeTo16k(pkt.Payload)
					if err != nil {
						continue
					}
					auditSamples += len(pcm16)
					rt.AppendPCM16k(pcm16)
					continue
				}
				// ★方向 B 优先：DashScope 直连客户端（旁路已验证手机 PCM 有效）。
				if dash != nil && codec != nil {
					pcm16, err := codec.DecodeTo16k(pkt.Payload)
					if err != nil {
						continue
					}
					dash.AppendPCM16k(pcm16)
				} else if gw != nil && codec != nil {
					// 方案 A 回退：qwen-audio-agent Gateway。
					pcm16, err := codec.DecodeTo16k(pkt.Payload)
					if err != nil {
						log.Printf("[MEDIA] %s decode failed: %v (pkt=%dB)", userID, err, len(pkt.Payload))
						continue
					}
					auditSamples += len(pcm16)
					gw.AppendPCM16k(pcm16)
				} else {
					// 回退：原 ASR provider。
					if err := s.pipeline.FeedFrame(pkt.Payload); err != nil {
						log.Printf("[MEDIA] feed failed: %v", err)
						break
					}
				}
			}
		}()
	})

	m.mu.Unlock()
	log.Printf("[MEDIA] session init user=%s session=%s", userID, sessionID)
	s.SendReady("connected", "")
}

// HandleSignal 处理 agentSignal（SDP/ICE）。
func (m *Manager) HandleSignal(userID string, signal map[string]interface{}) {
	m.mu.Lock()
	s := m.sessions[userID]
	m.mu.Unlock()
	if s == nil {
		return
	}
	sig, _ := signal["signal"].(map[string]interface{})
	if sig == nil {
		return
	}
	typ, _ := sig["type"].(string)
	switch typ {
	case "offer":
		sdp, _ := sig["sdp"].(string)
		if err := s.pc.SetRemoteDescription(webrtc.SessionDescription{
			Type: webrtc.SDPTypeOffer, SDP: sdp,
		}); err != nil {
			log.Printf("[MEDIA] SetRemoteDescription failed: %v", err)
			return
		}
		answer, err := s.pc.CreateAnswer(nil)
		if err != nil {
			log.Printf("[MEDIA] CreateAnswer failed: %v", err)
			return
		}
		if err := s.pc.SetLocalDescription(answer); err != nil {
			log.Printf("[MEDIA] SetLocalDescription failed: %v", err)
			return
		}
		s.send("agentSignal", map[string]interface{}{
			"signal": map[string]interface{}{"type": "answer", "sdp": answer.SDP},
		})
		log.Printf("[MEDIA] answer sent to %s", userID)
	case "ice":
		candidate, _ := sig["candidate"].(string)
		mid, _ := sig["sdp_mid"].(string)
		// ★安全转换：JSON 数字解码为 float64，若用 .(int) 断言会 panic → 桥崩 → ICE 丢。
		//   兼容 int / float64 / nil。
		var idx uint16
		switch v := sig["sdp_m_line_index"].(type) {
		case float64:
			idx = uint16(v)
		case int:
			idx = uint16(v)
		case int64:
			idx = uint16(v)
		}
		_ = s.pc.AddICECandidate(webrtc.ICECandidateInit{
			Candidate:     candidate,
			SDPMid:        &mid,
			SDPMLineIndex: &idx,
		})
	}
}

// HandleHangup 处理 agentHangup（用户或对端结束）。
func (m *Manager) HandleHangup(userID string) {
	m.mu.Lock()
	s := m.sessions[userID]
	delete(m.sessions, userID)
	m.mu.Unlock()
	if s == nil {
		return
	}
	log.Printf("[MEDIA] hangup user=%s", userID)
	// ★挂断即释放 qwen 网关上行连接（懒连接的对称操作）：网关只保有一个
	//   活跃会话，挂断后继续占用会与下一次来电/其他客户端互踢形成重连风暴。
	if m.webrtcUp != nil {
		m.webrtcUp.Close()
	}
	s.Close()
}
