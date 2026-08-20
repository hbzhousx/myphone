// Opus↔PCM 转码层（cgo libopus，hraban/opus）。
//
// 方向（方案 A：media-agent 保留 Pion WebRTC，转码后接 qwen-audio-agent Gateway）：
//   - 入站：手机 WebRTC Opus 帧 → 解码 PCM 16kHz mono → 送 Gateway audio.append
//   - 出站：Gateway audio.delta 的 PCM 24kHz → 重采样 24k→48k → 编码 Opus 48k
//     → WriteRTP 回手机（Pion TrackLocalStaticRTP 的 Opus 是 48kHz）
//
// ★构建：本文件启用 cgo，media-agent 需 CGO_ENABLED=1 链接 libopus（服务器已装
// opus-devel）。仅 media-agent 使用，myphone-server 保持纯静态不受影响。
package media

import (
	"log"
	"sync"

	"github.com/hraban/opus"
)

const (
	gatewayInputRate  = 16000 // Gateway 输入采样率（PCM16k）
	gatewayOutputRate = 24000 // Gateway 输出采样率（PCM24k）
	webrtcRate        = 48000 // WebRTC Opus 采样率
	channels          = 1     // 单声道
	frameSize16k      = 320   // 16k * 20ms
	frameSize24k      = 480   // 24k * 20ms
	frameSize48k      = 960   // 48k * 20ms
)

// OpusCodec 持有 libopus 编解码器（48kHz 单声道）。
// 入站：手机 Opus(48k) → PCM48k → 降采样 PCM16k（送 Gateway）。
// 出站：Gateway PCM24k → 升采样 PCM48k → 编码 Opus(48k)（回手机）。
type OpusCodec struct {
	enc48 *opus.Encoder
	dec48 *opus.Decoder
	mu    sync.Mutex
}

// NewOpusCodec 初始化 libopus 编解码器（48kHz 单声道）。
func NewOpusCodec() (*OpusCodec, error) {
	enc, err := opus.NewEncoder(webrtcRate, channels, opus.AppVoIP)
	if err != nil {
		return nil, err
	}
	// 16kbps 极低码率 + FEC/DTX，与客户端 OpusConfig.forTier(moderate) 对齐，
	// 保证 AI 通话在弱网下也不至于听不见。
	if err := enc.SetBitrate(16000); err != nil {
		log.Printf("[OPUS] set bitrate failed: %v", err)
	}
	if err := enc.SetInBandFEC(true); err != nil {
		log.Printf("[OPUS] fec failed: %v", err)
	}
	if err := enc.SetDTX(true); err != nil {
		log.Printf("[OPUS] dtx failed: %v", err)
	}
	dec, err := opus.NewDecoder(webrtcRate, channels)
	if err != nil {
		return nil, err
	}
	return &OpusCodec{enc48: enc, dec48: dec}, nil
}

// DecodeTo16k 把一帧手机 Opus(48k) 解码为 PCM 16k 单声道（送 Gateway）。
// 返回 int16 PCM(16k)。frameSize 按 20ms 推：48k*20ms=960 samples。
func (c *OpusCodec) DecodeTo16k(opusFrame []byte) ([]int16, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	pcm48 := make([]int16, frameSize48k)
	n, err := c.dec48.Decode(opusFrame, pcm48)
	if err != nil {
		return nil, err
	}
	// 48k→16k 抽 1/3。
	pcm16 := make([]int16, n/3)
	for i := range pcm16 {
		pcm16[i] = pcm48[i*3]
	}
	return pcm16, nil
}

// EncodeFrom24k 把 Gateway 的 PCM 24k 重采样到 48k 并编码为 Opus 帧（回手机）。
// 线性插值 24k→48k（每 2 个输入样本插 1 个）。
func (c *OpusCodec) EncodeFrom24k(pcm24 []int16) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	pcm48 := resampleUp(pcm24, 2)
	out := make([]byte, 2048)
	n, err := c.enc48.Encode(pcm48, out)
	if err != nil {
		return nil, err
	}
	return out[:n], nil
}

// resampleUp 线性插值升采样（factor=2:24k→48k）。
func resampleUp(pcm []int16, factor int) []int16 {
	out := make([]int16, len(pcm)*factor)
	for i := 0; i < len(pcm); i++ {
		out[i*factor] = pcm[i]
		if i+1 < len(pcm) {
			out[i*factor+1] = int16((int(pcm[i]) + int(pcm[i+1])) / 2)
		} else {
			out[i*factor+1] = pcm[i]
		}
	}
	return out
}
