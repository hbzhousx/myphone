package media

import (
	"math/rand"
	"testing"
)

// TestOpusRoundTrip48to16 验证：48k PCM → 编码 Opus → 解码 → 降采样 16k。
// 这是入站路径（手机 Opus → Gateway PCM16k）的核心正确性。
func TestOpusRoundTrip48to16(t *testing.T) {
	c, err := NewOpusCodec()
	if err != nil {
		t.Fatalf("NewOpusCodec: %v", err)
	}
	// 48k 20ms = 960 samples。
	pcm48 := make([]int16, frameSize48k)
	for i := range pcm48 {
		pcm48[i] = int16(rand.Intn(2000) - 1000)
	}
	// 编码。
	out := make([]byte, 2048)
	n, err := c.enc48.Encode(pcm48, out)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if n == 0 {
		t.Fatalf("encoded empty")
	}
	// 解码 + 降采样 16k。
	pcm16, err := c.DecodeTo16k(out[:n])
	if err != nil {
		t.Fatalf("DecodeTo16k: %v", err)
	}
	// 16k 20ms = 320 samples。
	if len(pcm16) != frameSize16k {
		t.Fatalf("expected %d PCM16 samples, got %d", frameSize16k, len(pcm16))
	}
	// 非全零（确认有实际音频能量）。
	sum := 0
	for _, s := range pcm16 {
		if s < 0 {
			sum += -int(s)
		} else {
			sum += int(s)
		}
	}
	if sum == 0 {
		t.Fatalf("decoded PCM is all zero")
	}
}

// TestOpusEncodeFrom24k 验证：Gateway PCM24k → 升采样 48k → 编码 Opus。
func TestOpusEncodeFrom24k(t *testing.T) {
	c, err := NewOpusCodec()
	if err != nil {
		t.Fatalf("NewOpusCodec: %v", err)
	}
	// 24k 20ms = 480 samples。
	pcm24 := make([]int16, frameSize24k)
	for i := range pcm24 {
		pcm24[i] = int16(rand.Intn(2000) - 1000)
	}
	opusFrame, err := c.EncodeFrom24k(pcm24)
	if err != nil {
		t.Fatalf("EncodeFrom24k: %v", err)
	}
	if len(opusFrame) == 0 {
		t.Fatalf("encoded opus empty")
	}
	// 编码出的 Opus 应能被 48k 解码器解码（回环到 DecodeTo16k 验证非空）。
	pcm16, err := c.DecodeTo16k(opusFrame)
	if err != nil {
		t.Fatalf("decode back: %v", err)
	}
	if len(pcm16) == 0 {
		t.Fatalf("decoded back empty")
	}
}
