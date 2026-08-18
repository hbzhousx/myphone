// ASR provider：把用户语音（Opus 帧流）转成文本。
//
// ★零本地编解码：媒体端点把 OnTrack 收到的 Opus RTP payload 原样交给 [ASR.Feed]，
// 是否转 PCM 由实现决定（外部 ASR 服务多数直接接受 opus）。
//
// 最终识别文本通过构造时的 onFinal 回调上报（is_final=true 时才触发管线）。
package media

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/url"
	"sync"

	"github.com/gorilla/websocket"
)

// ASR 抽象语音识别。
type ASR interface {
	// Feed 送入一帧用户语音（Opus 编码）。返回 error 触发会话结束。
	Feed(sessionID string, frame []byte) error
	// Close 结束识别会话（释放资源）。
	Close(sessionID string)
}

// ASRConfig 是 HTTP ASR 实现的配置。
type ASRConfig struct {
	URL     string // 外部 ASR 服务（WS），空则禁用真实识别
	Token   string
	OnFinal func(userID, sessionID, text string) // 最终识别文本回调
}

// HTTPASR 把帧经 WS 转发给外部 ASR（mock/真实提供方），回包文本触发 OnFinal。
// 未配置 URL 时仅计数（链路冒烟）。
type HTTPASR struct {
	cfg      ASRConfig
	userID   string
	mu       sync.Mutex
	frameCnt map[string]int      // sessionID → 收到的帧数
	conns    map[string]*socket  // sessionID → WS 连接
	closed   map[string]struct{} // sessionID → 已关闭标记
}

type socket struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func NewHTTPASR(cfg ASRConfig, userID string) *HTTPASR {
	a := &HTTPASR{
		cfg:      cfg,
		userID:   userID,
		frameCnt: make(map[string]int),
		conns:    make(map[string]*socket),
		closed:   make(map[string]struct{}),
	}
	return a
}

// Feed 逐帧转发到外部 ASR（WS）。首次送帧建立连接。
func (a *HTTPASR) Feed(sessionID string, frame []byte) error {
	a.mu.Lock()
	a.frameCnt[sessionID]++
	n := a.frameCnt[sessionID]
	closed := a.isClosedLocked(sessionID)
	a.mu.Unlock()

	if a.cfg.URL == "" {
		if n%250 == 0 {
			log.Printf("[ASR] (no provider) session=%s frames=%d", sessionID, n)
		}
		return nil
	}
	if closed {
		return nil
	}
	conn, err := a.ensureConn(sessionID)
	if err != nil {
		// 连接失败：降级为计数（不中断语音）。
		if n%250 == 0 {
			log.Printf("[ASR] connect failed (degraded): %v", err)
		}
		return nil
	}
	conn.mu.Lock()
	defer conn.mu.Unlock()
	// 帧以 JSON {frame: base64} 发送（mock ASR 读取）。
	msg := map[string]interface{}{"frame": base64.StdEncoding.EncodeToString(frame)}
	b, _ := json.Marshal(msg)
	return conn.conn.WriteMessage(websocket.TextMessage, b)
}

func (a *HTTPASR) Close(sessionID string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.closed[sessionID] = struct{}{}
	if s, ok := a.conns[sessionID]; ok {
		_ = s.conn.Close()
		delete(a.conns, sessionID)
	}
	delete(a.frameCnt, sessionID)
}

func (a *HTTPASR) isClosedLocked(sessionID string) bool {
	_, ok := a.closed[sessionID]
	return ok
}

// ensureConn 建立（或复用）某会话的 ASR WS 连接，并启动读循环。
func (a *HTTPASR) ensureConn(sessionID string) (*socket, error) {
	a.mu.Lock()
	if s, ok := a.conns[sessionID]; ok {
		a.mu.Unlock()
		return s, nil
	}
	u, err := url.Parse(a.cfg.URL)
	if err != nil {
		a.mu.Unlock()
		return nil, err
	}
	q := u.Query()
	q.Set("session_id", sessionID)
	q.Set("user_id", a.userID)
	u.RawQuery = q.Encode()
	conn, _, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if err != nil {
		a.mu.Unlock()
		return nil, err
	}
	s := &socket{conn: conn}
	a.conns[sessionID] = s
	a.mu.Unlock()

	go a.readLoop(sessionID, conn)
	return s, nil
}

// readLoop 读外部 ASR 的回包（{text, is_final}），is_final=true 触发 OnFinal。
func (a *HTTPASR) readLoop(sessionID string, conn *websocket.Conn) {
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			return
		}
		var out struct {
			Text    string `json:"text"`
			IsFinal bool   `json:"is_final"`
		}
		if json.Unmarshal(msg, &out) != nil || out.Text == "" {
			continue
		}
		if out.IsFinal && a.cfg.OnFinal != nil {
			log.Printf("[ASR] final session=%s text=%q", sessionID, out.Text)
			a.cfg.OnFinal(a.userID, sessionID, out.Text)
		}
	}
}

