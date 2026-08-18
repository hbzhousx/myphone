// 全双工对话管线：入站语音 → ASR → Agent → ①出站 TTS ②聊天历史回流 ③字幕。
//
// 数据流（单向，每段独立 goroutine，barge-in 通过 cancel 中止播放）：
//
//	OnTrack RTP → FeedFrame → ASR.Feed（帧进 provider）
//	   └─ onFinal(userText)  → 打断当前 TTS → Agent.Query → {Text, Actions}
//	        ├─ TTS.Synthesize → PlayFrame（出站语音）
//	        ├─ 回 chatMessage（bot 明文旁路，落库聊天历史）
//	        └─ agentTranscript{agent}
//
// 字幕：用户最终识别文本 → agentTranscript{user, is_final:true}。
package media

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"sync"
	"sync/atomic"
	"time"
)

// Pipeline 组装一个会话的 ASR→Agent→TTS 流程。
type Pipeline struct {
	session *Session
	asr     ASR
	tts     TTS
	agent   AgentText
	userID  string

	// barge-in：正在播放的 TTS 任务可被取消。
	mu         sync.Mutex
	playCancel chan struct{}

	// 字幕序号。
	seq int64

	closed atomic.Bool
}

func NewPipeline(session *Session, asr ASR, tts TTS, agent AgentText, userID string) *Pipeline {
	p := &Pipeline{
		session:    session,
		asr:        asr,
		tts:        tts,
		agent:      agent,
		userID:     userID,
		playCancel: make(chan struct{}),
	}
	// ASR 最终识别文本 → 主对话线程。
	if ha, ok := asr.(*HTTPASR); ok {
		ha.cfg.OnFinal = p.onUserFinal
	}
	return p
}

// FeedFrame 送入一帧用户语音（Opus RTP payload）→ ASR。
func (p *Pipeline) FeedFrame(frame []byte) error {
	if p.closed.Load() {
		return nil
	}
	return p.asr.Feed(p.session.sessionID, frame)
}

// onUserFinal 收到一条最终识别文本。
func (p *Pipeline) onUserFinal(userID, sessionID, text string) {
	if p.closed.Load() {
		return
	}
	// 用户最终字幕（is_final=true）。
	p.nextSeq(func(seq int) {
		p.session.SendTranscript(seq, "user", text, true)
	})

	// 打断正在播放的 TTS（barge-in）。
	p.interruptPlay()

	// 调智能体。
	reply, err := p.agent.Query(p.session.sessionID, text)
	if err != nil {
		log.Printf("[PIPE] agent query failed: %v", err)
		p.session.SendReady("ended", "agent_error")
		p.session.SendHangup()
		return
	}

	// ①出站 TTS（异步播放；barge-in 可打断）。
	go p.playReply(reply.Text)

	// ②聊天历史回流（bot 明文 chatMessage）+ ③Agent 字幕。
	p.pushChatMessage(reply.Text, reply.Actions)
	p.nextSeq(func(seq int) {
		p.session.SendTranscript(seq, "agent", reply.Text, true)
	})
}

// playReply 播放 TTS（可被 barge-in 打断）。
func (p *Pipeline) playReply(text string) {
	p.mu.Lock()
	cancel := make(chan struct{})
	prev := p.playCancel
	p.playCancel = cancel
	p.mu.Unlock()
	close(prev) // 通知上一段播放结束

	n, err := p.tts.Synthesize(p.session.sessionID, text, func(frame []byte) {
		select {
		case <-cancel:
			return // 已打断
		default:
			p.session.PlayFrame(frame)
			time.Sleep(20 * time.Millisecond) // 与 20ms 帧节奏对齐
		}
	})
	if err != nil {
		log.Printf("[PIPE] tts failed: %v", err)
	}
	log.Printf("[PIPE] tts done session=%s frames=%d", p.session.sessionID, n)
}

// interruptPlay 打断当前播放（barge-in）。
func (p *Pipeline) interruptPlay() {
	p.mu.Lock()
	cancel := p.playCancel
	p.mu.Unlock()
	if cancel != nil {
		close(cancel)
	}
}

// pushChatMessage 把 Agent 回复以 bot 明文 chatMessage 推回聊天历史。
// 动作以 agent_payload 附带（客户端落库 action 卡片）。
func (p *Pipeline) pushChatMessage(text string, actions []map[string]interface{}) {
	plain := map[string]interface{}{"kind": "agent", "body": text}
	if len(actions) > 0 {
		plain["kind"] = "action"
		plain["agent_payload"] = actions[0]
	}
	plainJSON, _ := json.Marshal(plain)
	now := time.Now().UnixMilli()
	payload := map[string]interface{}{
		"message_id": "agent-" + nowStr(now),
		"ciphertext": base64.StdEncoding.EncodeToString(plainJSON),
		"counter":    0,
		"plaintext":  true,
	}
	p.session.SendToServer(p.userID, "chatMessage", payload)
}

func nowStr(ms int64) string {
	t := time.UnixMilli(ms)
	return t.Format("20060102150405")
}

func (p *Pipeline) nextSeq(fn func(seq int)) {
	seq := int(atomic.AddInt64(&p.seq, 1))
	fn(seq)
}

// Close 释放管线资源。
func (p *Pipeline) Close() {
	if p.closed.Swap(true) {
		return
	}
	p.interruptPlay()
	p.asr.Close(p.session.sessionID)
}
