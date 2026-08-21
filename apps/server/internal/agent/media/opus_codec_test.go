package media

import (
	"encoding/base64"
	"math/rand"
	"os"
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

// TestEncodeLargeDeltaFromProd:生产日志提取的真实 DashScope delta
// (7680 samples @24k ≈ 320ms)。旧 bug：整块一次 Encode 超 libopus 帧上限
// 全丢；修复后按 20ms 切帧应出 16 帧。依赖 /tmp/real_delta.b64(无则跳过)。
func TestEncodeLargeDeltaFromProd(t *testing.T) {
	b64, err := os.ReadFile("/tmp/real_delta.b64")
	if err != nil {
		t.Skip("no /tmp/real_delta.b64")
	}
	raw := string(b64)
	for len(raw) > 0 && raw[len(raw)-1] == '\n' {
		raw = raw[:len(raw)-1]
	}
	buf, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("base64: %v", err)
	}
	pcm := make([]int16, len(buf)/2)
	for i := range pcm {
		pcm[i] = int16(buf[i*2]) | int16(buf[i*2+1])<<8
	}
	t.Logf("decoded %d bytes = %d samples @24k = %.0fms", len(buf), len(pcm), float64(len(pcm))*1000/24000)

	codec, err := NewOpusCodec()
	if err != nil {
		t.Fatalf("NewOpusCodec: %v", err)
	}
	// 模拟 dashscope_client.go 的切帧逻辑。
	const frameSamples = 480
	ok, fail := 0, 0
	for start := 0; start < len(pcm); start += frameSamples {
		end := start + frameSamples
		if end > len(pcm) {
			end = len(pcm)
		}
		chunk := pcm[start:end]
		if len(chunk) < frameSamples {
			full := make([]int16, frameSamples)
			copy(full, chunk)
			chunk = full
		}
		opus, err := codec.EncodeFrom24k(chunk)
		if err != nil {
			fail++
			t.Logf("  frame %d FAIL: %v (chunk=%d)", start/frameSamples, err, len(chunk))
			continue
		}
		ok++
		t.Logf("  frame %d OK: %d bytes", start/frameSamples, len(opus))
	}
	t.Logf("== %d OK, %d FAIL ==", ok, fail)
	if fail > 0 {
		t.Errorf("有 %d 帧编码失败", fail)
	}
}
