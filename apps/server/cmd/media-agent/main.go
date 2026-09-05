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

	// v1.50+ 方案 A：配置 AGENT_GATEWAY_URL 时，接入 qwen-audio-agent 语音引擎
	// （libopus 转码 Opus↔PCM16k/24k）。未配置则回退 asr/tts/agent 三件套。
	// ★方向 B：AGENT_DASHSCOPE_KEY 配置时直连 DashScope(优先于 Gateway)。
	// ★vllm-omni Realtime 直连：AGENT_VLLMOMNI_URL 配置时优先于以上全部
	//   （OpenAI Realtime WS，MiniCPM-o native full-duplex，绕过 Node 网关）。
	codec, err := media.NewOpusCodec()
	if err != nil {
		log.Fatalf("[MEDIA-AGENT] NewOpusCodec failed: %v (需 libopus-dev + CGO)", err)
	}
	// vllm-omni Realtime 直连（AGENT_VLLMOMNI_URL 非空即独占）：手机 opus →
	// PCM16k → input_audio_buffer.append；response.audio.delta(PCM24k) → opus
	// → 手机播放。打断为服务端 VAD 自动 barge-in，客户端只清播放队列。
	if os.Getenv("AGENT_VLLMOMNI_URL") != "" {
		rt := media.NewRealtimeClient(media.RealtimeConfigFromEnv())
		var pcmBuf []int16
		var loggedChunk bool
		rt.SetCallbacks(
			// assistant 文本：delta 只更新字幕，final=整轮终稿（字幕+聊天回流）。
			func(text string, final bool) {
				if final {
					manager.TranscriptSink(text)
				} else {
					manager.TranscriptDelta(text)
				}
			},
			func(pcm24 []int16) {
				// 与 gateway 分支同款重分帧：上游整块到达，按 480 样本
				// （20ms@24k）切帧编码，与 PlayFrame 的 20ms 节拍器对齐。
				// onAudioDelta 仅由 readLoop 协程调用，无并发。
				const chunk24 = 480 // 20ms @24k
				if !loggedChunk {
					loggedChunk = true
					log.Printf("[VLLM] downlink pcm24 first chunk=%d samples", len(pcm24))
				}
				pcmBuf = append(pcmBuf, pcm24...)
				for len(pcmBuf) >= chunk24 {
					frame, err := codec.EncodeFrom24k(pcmBuf[:chunk24])
					if err != nil {
						log.Printf("[VLLM] opus encode failed: %v", err)
					} else {
						manager.ReplySink(frame)
					}
					pcmBuf = pcmBuf[chunk24:]
				}
				if len(pcmBuf) > chunk24*10 { // 残余上限 200ms，异常残块直接丢弃
					pcmBuf = pcmBuf[:0]
				}
			},
			// 服务端 barge-in（response.listen）：清下行残块 + 清播放队列。
			func() {
				pcmBuf = pcmBuf[:0]
				manager.ClearPlayback()
			},
			// session.created：清下行残块（armed 日志由客户端内部打）。
			func() {
				pcmBuf = pcmBuf[:0]
			},
			func(err error) { log.Printf("[VLLM] error: %v", err) },
		)
		manager.SetVllmOmni(rt, codec)
		log.Printf("[MEDIA-AGENT] vllm-omni realtime engine: %s", os.Getenv("AGENT_VLLMOMNI_URL"))
	} else if os.Getenv("AGENT_WEBRTC_URL") != "" {
		// ★WebRTC 上行优先：配置 AGENT_WEBRTC_URL 时，手机 opus 原样转发到
		//   qwen-audio-agent 的 WebRTC 入口（全程 WebRTC 不转码），替代 WS Gateway。
		//   ★独占（2026-08-30）：WebRTC 模式下不再启动 DashScope / WS Gateway
		//   客户端 —— WS Gateway 连 /api/realtime 会在网关侧创建幻影会话，
		//   占住 llama-omni 唯一会话名额；通话建立时幻影被踢 → 会话销毁重建
		//   （13:40 通话实测：开头 3s 语音被丢弃 + GPU 重复初始化）。
		wUp := media.NewWebRTCUpstreamClient()
		if wUp != nil {
			manager.SetWebRTCUpstream(wUp)
			// ★下行：qwen-audio-agent 的回复音频 → 当前活跃通话的手机播放。
			wUp.SetReplyHandler(manager.ReplySink)
			// ★下行：模型回复文字 → 手机字幕。
			wUp.SetTranscriptHandler(manager.TranscriptSink)
			log.Printf("[MEDIA-AGENT] webrtc upstream: %s", os.Getenv("AGENT_WEBRTC_URL"))
		}
	} else if os.Getenv("AGENT_DASHSCOPE_KEY") != "" {
		ds := media.NewDashScopeClient(codec)
		if ds != nil {
			// 回调由每个会话 bindDash 绑定（回复音频→PlayFrame、文本→字幕/回流）。
			manager.SetDashScope(ds, codec)
			log.Printf("[MEDIA-AGENT] dashscope voice engine: %s", os.Getenv("AGENT_DASHSCOPE_MODEL"))
		}
	} else if os.Getenv("AGENT_GATEWAY_URL") != "" {
		gw := media.NewGatewayClient(codec)
		// ★下行接线（2026-08-30 根因二号）：GatewayClient.SetCallbacks 此前从未
		//   被调用，onAudioDelta 恒为 nil → dispatch("audio.delta") 静默丢弃 AI
		//   回复音频（19:09 通话：llama-omni 日志实锤模型已出声，media-agent
		//   零下行）→ 通话全程无声。对齐上方 WebRTC 上行模式：PCM24k → opus →
		//   当前活跃会话手机播放；assistant 文本 → 字幕。
		var pcmBuf []int16
		var loggedChunk bool
		gw.SetCallbacks(
			// ★2026-09-03 字幕官方语义：delta=流式增量（只更新字幕），final=整轮
			//   终稿（字幕 + 聊天回流，每轮一条）。
			func(role, content string, final bool) {
				if role != "assistant" {
					return
				}
				if final {
					manager.TranscriptSink(content)
				} else {
					manager.TranscriptDelta(content)
				}
			},
			func(pcm24 []int16) {
				// ★重分帧（2026-08-30 根因三号）：上游 llama-omni 以 ~1s 整块
				//   （24000 samples）发 audio.delta，libopus 单帧上限 120ms ——
				//   EncodeFrom24k 每帧报 "opus: invalid argument"（OPUS_BAD_ARG）。
				//   缓冲后按 480 samples（20ms@24k）切帧编码，与 PlayFrame 的
				//   20ms 节拍器对齐。onAudioDelta 仅由 readLoop 协程调用，无并发。
				const chunk24 = 480 // 20ms @24k
				if !loggedChunk {
					loggedChunk = true
					log.Printf("[GATEWAY] downlink pcm24 first chunk=%d samples", len(pcm24))
				}
				pcmBuf = append(pcmBuf, pcm24...)
				for len(pcmBuf) >= chunk24 {
					frame, err := codec.EncodeFrom24k(pcmBuf[:chunk24])
					if err != nil {
						log.Printf("[GATEWAY] opus encode failed: %v", err)
					} else {
						manager.ReplySink(frame)
					}
					pcmBuf = pcmBuf[chunk24:]
				}
				if len(pcmBuf) > chunk24*10 { // 残余上限 200ms，异常残块直接丢弃
					pcmBuf = pcmBuf[:0]
				}
			},
			func() {
				pcmBuf = pcmBuf[:0]
				log.Printf("[GATEWAY] voice ready — downlink armed")
			},
			func(err error) { log.Printf("[GATEWAY] error: %v", err) },
		)
		manager.SetGateway(gw, codec)
		log.Printf("[MEDIA-AGENT] gateway voice engine: %s", os.Getenv("AGENT_GATEWAY_URL"))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/bridge", bs.Handler)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	log.Printf("[MEDIA-AGENT] listening on %s (gateway=%q asr=%q tts=%q agent=%q)",
		addr, os.Getenv("AGENT_GATEWAY_URL"), os.Getenv("AGENT_ASR_URL"), os.Getenv("AGENT_TTS_URL"), agentURL)
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
