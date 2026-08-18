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
	seq  uint16
	ts   uint32
	ssrc uint32

	mu     sync.Mutex
	closed bool
}

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

// PlayFrame 写一帧 Opus 到出站 track（TTS 播放）。
func (s *Session) PlayFrame(frame []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.outTrack == nil {
		return
	}
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

// Close 释放 PeerConnection 与管线。
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

// HandleInit 处理 agentInit（新会话，替换旧会话）。
func (m *Manager) HandleInit(userID, sessionID string) {
	m.mu.Lock()
	if old := m.sessions[userID]; old != nil {
		old.Close()
		delete(m.sessions, userID)
	}
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{ICEServers: m.iceServers})
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
		userID:    userID,
		sessionID: sessionID,
		pc:        pc,
		outTrack:  outTrack,
		sig:       m.sig,
		ssrc:      ssrc,
	}
	s.pipeline = NewPipeline(s, m.asr, m.tts, m.agent, userID)
	m.sessions[userID] = s

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		j := c.ToJSON()
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
		// 入站用户语音：逐 RTP 包抽 Opus payload → ASR provider。
		go func() {
			for {
				pkt, _, err := tr.ReadRTP()
				if err != nil {
					break
				}
				if len(pkt.Payload) == 0 {
					continue
				}
				if err := s.pipeline.FeedFrame(pkt.Payload); err != nil {
					log.Printf("[MEDIA] feed failed: %v", err)
					break
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
		mid := sig["sdp_mid"].(string)
		idx := uint16(sig["sdp_m_line_index"].(int))
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
	s.Close()
}
