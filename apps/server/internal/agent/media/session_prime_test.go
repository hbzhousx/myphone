// 预缓冲状态机单测（★2026-09-12）：锁"何时攒帧、何时开口"。
// 背景：引擎供帧比实时慢 ~3%，零缓冲播放时欠载逐块累加，长回复尾部攒成
// 秒级静音（用户听感="尾句卡顿"）。攒够 1200ms 再开口把这段迟到吸收掉。
package media

import (
	"testing"
	"time"
)

// newPrimeSession 造一个只测状态机的会话（无 PeerConnection/track，stepPrime
// 不触碰它们）。
func newPrimeSession() *Session {
	return &Session{playSignal: make(chan struct{}, 8)}
}

// fillQueue 往队列塞 n 帧。
func fillQueue(s *Session, n int) {
	for i := 0; i < n; i++ {
		s.playQueue = append(s.playQueue, make([]byte, 10))
	}
}

// 首帧（未播过任何东西）必须进入攒帧态、不立即开口。
func TestPrimeFirstFrameWaits(t *testing.T) {
	s := newPrimeSession()
	fillQueue(s, 1)
	if s.stepPrime() {
		t.Fatal("首帧应进入攒帧态（不发送），实际放行")
	}
	if !s.priming {
		t.Fatal("首帧后 priming 应为 true")
	}
}

// 攒够 prebufferFrames = 1200ms 音频才开口。
func TestPrimeReleasesAtFrameQuota(t *testing.T) {
	s := newPrimeSession()
	s.priming, s.primeDeadline = true, time.Now().Add(prebufferDuration)
	fillQueue(s, prebufferFrames-1)
	if s.stepPrime() {
		t.Fatalf("攒到 %d 帧不应放行（阈值 %d）", prebufferFrames-1, prebufferFrames)
	}
	fillQueue(s, 1)
	if !s.stepPrime() {
		t.Fatalf("攒满 %d 帧应放行", prebufferFrames)
	}
	if s.priming {
		t.Fatal("放行后 priming 应为 false")
	}
}

// 短回复（音频不足 1200ms）到时限也必须开口，不能无限等。
func TestPrimeReleasesAtDeadline(t *testing.T) {
	s := newPrimeSession()
	s.priming, s.primeDeadline = true, time.Now().Add(-time.Millisecond)
	fillQueue(s, 3)
	if !s.stepPrime() {
		t.Fatal("过时限应放行（短回复兜底）")
	}
}

// 一轮中间的块间隔（< primeIdleGap）不得重置预缓冲：放行后继续直发。
func TestPrimeNotRearmedMidResponse(t *testing.T) {
	s := newPrimeSession()
	s.lastFrameTime = time.Now().Add(-300 * time.Millisecond)
	fillQueue(s, 1)
	if !s.stepPrime() {
		t.Fatal("一轮中间隔不应进入攒帧态，应直接发送")
	}
	if s.priming {
		t.Fatal("一轮中间隔误触发攒帧 → 会在原有停顿上再叠 1.2s 静音")
	}
}

// 播放器静默超过 primeIdleGap = 新一轮回复，重新攒帧。
func TestPrimeRearmedAfterIdleGap(t *testing.T) {
	s := newPrimeSession()
	s.lastFrameTime = time.Now().Add(-primeIdleGap - time.Second)
	fillQueue(s, 1)
	if s.stepPrime() {
		t.Fatal("静默超阈值应视为新一轮，重新攒帧")
	}
	if !s.priming {
		t.Fatal("静默超阈值后 priming 应为 true")
	}
}

// 打断清队列后必须重新攒帧（否则打断后的每一轮都退化成零缓冲）。
func TestClearPlayQueueRearmsPrime(t *testing.T) {
	s := newPrimeSession()
	s.priming, s.primeArmed = true, false
	fillQueue(s, 5)
	s.ClearPlayQueue()
	if s.playQueue != nil {
		t.Fatalf("清队列后 playQueue 应为空，实际 %d 帧", len(s.playQueue))
	}
	if s.priming {
		t.Fatal("清队列后应退出攒帧态（旧 deadline 已失效）")
	}
	if !s.primeArmed {
		t.Fatal("清队列后应置 primeArmed，让下一轮重新攒帧")
	}
	// 下一轮首帧到达 → 重新进入攒帧态。
	fillQueue(s, 1)
	if s.stepPrime() {
		t.Fatal("打断后的新一轮首帧不应立即放行")
	}
}
