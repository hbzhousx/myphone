// Agent provider：把用户识别文本交给智能体，拿回复（文本 + 动作）。
package media

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"time"
)

// AgentReply 是智能体对一条用户输入的整体回复。
type AgentReply struct {
	Text    string                   `json:"text"`
	Actions []map[string]interface{} `json:"actions"`
}

// AgentText 抽象智能体文本交互。
type AgentText interface {
	// Query 提交用户文本，返回回复。
	Query(sessionID, userText string) (AgentReply, error)
}

// AgentTextConfig 是 HTTP Agent 实现配置。
type AgentTextConfig struct {
	URL   string // 外部 Agent 服务，空则回退为本地回声
	Token string
}

// HTTPAgentText 是接口先行的默认实现：POST {user_id, text} → {text, actions}。
// URL 为空时回退本地回声（含测试动作卡片），保证无外部服务也可全链路演示。
type HTTPAgentText struct {
	cfg     AgentTextConfig
	userID  string
	httpCli *http.Client
}

func NewHTTPAgentText(cfg AgentTextConfig, userID string) *HTTPAgentText {
	return &HTTPAgentText{
		cfg:     cfg,
		userID:  userID,
		httpCli: &http.Client{Timeout: 15 * time.Second},
	}
}

func (a *HTTPAgentText) Query(sessionID, userText string) (AgentReply, error) {
	if a.cfg.URL == "" {
		// 本地回退：回声 + 演示动作卡片（无外部 Agent 也可验证全链路）。
		return AgentReply{
			Text: "（智能体未配置）你说了：" + userText,
			Actions: []map[string]interface{}{
				{
					"title":  "示例动作：已收到你的话",
					"status": "done",
					"detail": userText,
				},
			},
		}, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	body, _ := json.Marshal(map[string]string{
		"user_id": a.userID, "text": userText, "session_id": sessionID,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.URL, bytes.NewReader(body))
	if err != nil {
		return AgentReply{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	if a.cfg.Token != "" {
		req.Header.Set("Authorization", "Bearer "+a.cfg.Token)
	}
	resp, err := a.httpCli.Do(req)
	if err != nil {
		return AgentReply{}, err
	}
	defer resp.Body.Close()
	var out AgentReply
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return AgentReply{}, err
	}
	return out, nil
}
