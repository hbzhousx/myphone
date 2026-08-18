// TTS provider：把 Agent 文本合成语音（Opus 帧流），经 PlayFrame 出站播放。
//
// ★零本地编解码：出站不编 Opus——外部 TTS 服务返回**预编码 Opus 帧**，
// 媒体端点原样 WriteRTP。
package media

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// TTS 抽象语音合成。
type TTS interface {
	// Synthesize 合成一段文本为 Opus 帧流（顺序调用 PlayFrame 播放）。
	// 返回 frame 数；err 非空时管线记录失败但不中断会话。
	Synthesize(sessionID, text string, play func(frame []byte)) (int, error)
}

// TTSConfig 是 TTS 实现配置。
type TTSConfig struct {
	URL   string // 外部 TTS 服务，空则回退为不可用
	Token string
}

// HTTPTTS 调外部 TTS（POST {text} → {frames:[base64 Opus]}）逐帧播放。
// 未配置 URL 时不合成（返回 0 帧）。
type HTTPTTS struct {
	cfg     TTSConfig
	httpCli *http.Client
}

func NewHTTPTTS(cfg TTSConfig) *HTTPTTS {
	return &HTTPTTS{cfg: cfg, httpCli: &http.Client{Timeout: 15 * time.Second}}
}

func (t *HTTPTTS) Synthesize(sessionID, text string, play func(frame []byte)) (int, error) {
	if t.cfg.URL == "" {
		// 无 TTS：跳过播放（会话可继续文本交互）。
		log.Printf("[TTS] (no provider) session=%s text=%q skipped", sessionID, text)
		return 0, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	body, _ := json.Marshal(map[string]string{"text": text, "session_id": sessionID})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.cfg.URL, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if t.cfg.Token != "" {
		req.Header.Set("Authorization", "Bearer "+t.cfg.Token)
	}
	resp, err := t.httpCli.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	var out struct {
		Frames []string `json:"frames"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return 0, err
	}
	n := 0
	for _, f := range out.Frames {
		frame, err := base64.StdEncoding.DecodeString(f)
		if err != nil {
			continue
		}
		play(frame)
		n++
	}
	log.Printf("[TTS] synthesized session=%s text=%q frames=%d", sessionID, text, n)
	return n, nil
}
