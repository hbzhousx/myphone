// media-agent 是 v1.50 AI 语音通话的媒体端点：Pion WebRTC 全双工语音会话。
//
// 职责：
//   - 经 /bridge（WS，校验 AGENT_BRIDGE_TOKEN）与 myphone-server 信令互通；
//   - 每个用户会话建 PeerConnection，入站语音 → ASR，出站 TTS 帧 → 播放；
//   - Agent 文本/动作 → chatMessage 回流 + 字幕。
//
// 零本地 Opus 编解码（CGO_ENABLED=0 交叉编译）：编解码责任在外部 ASR/TTS。
//
// 部署：
//   AGENT_LISTEN_ADDR=0.0.0.0:8090
//   AGENT_BRIDGE_TOKEN=<shared secret>
//   AGENT_STUN_URL / AGENT_TURN_URL / AGENT_TURN_USERNAME / AGENT_TURN_CREDENTIAL
//   AGENT_ASR_URL / AGENT_TTS_URL / AGENT_TEXT_URL(缺省 BOT_AGENT_URL)
package main

import (
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/pion/webrtc/v3"

	"github.com/myphone/server/internal/agent/media"
)

func main() {
	token := os.Getenv("AGENT_BRIDGE_TOKEN")
	addr := os.Getenv("AGENT_LISTEN_ADDR")
	if addr == "" {
		addr = "0.0.0.0:8090"
	}

	asr := media.NewHTTPASR(media.ASRConfig{URL: os.Getenv("AGENT_ASR_URL")}, "")
	tts := media.NewHTTPTTS(media.TTSConfig{URL: os.Getenv("AGENT_TTS_URL")})
	agentURL := os.Getenv("AGENT_TEXT_URL")
	if agentURL == "" {
		agentURL = os.Getenv("BOT_AGENT_URL")
	}
	agentText := media.NewHTTPAgentText(media.AgentTextConfig{URL: agentURL, Token: token}, "")

	iceServers := buildICEServers()
	manager := media.NewManager(nil, asr, tts, agentText, iceServers)
	bs := media.NewBridgeServer(token, manager)
	// Manager 需要 Signaling 回推 → 桥（manager↔bridge 互相引用，用 setter 注入）。
	manager.SetSignaling(bs)

	mux := http.NewServeMux()
	mux.HandleFunc("/bridge", bs.Handler)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	log.Printf("[MEDIA-AGENT] listening on %s (asr=%q tts=%q agent=%q)",
		addr, os.Getenv("AGENT_ASR_URL"), os.Getenv("AGENT_TTS_URL"), agentURL)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("[MEDIA-AGENT] server error: %v", err)
	}
}

func buildICEServers() []webrtc.ICEServer {
	stun := os.Getenv("AGENT_STUN_URL")
	if stun == "" {
		stun = "stun:stun.l.google.com:19302"
	}
	servers := []webrtc.ICEServer{{URLs: []string{stun}}}
	turn := os.Getenv("AGENT_TURN_URL")
	if turn != "" {
		servers = append(servers, webrtc.ICEServer{
			URLs:       []string{turn},
			Username:   os.Getenv("AGENT_TURN_USERNAME"),
			Credential: os.Getenv("AGENT_TURN_CREDENTIAL"),
		})
	}
	// 逗号分隔多个 STUN。
	if multi := os.Getenv("AGENT_STUN_URLS"); multi != "" {
		urls := strings.Split(multi, ",")
		servers = []webrtc.ICEServer{{URLs: urls}}
	}
	return servers
}
