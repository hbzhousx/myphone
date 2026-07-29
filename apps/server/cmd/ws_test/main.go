package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

var passed, total int

func ok(name string, cond bool) {
	total++
	if cond {
		passed++
		fmt.Printf("  \033[92m✓\033[0m %s\n", name)
	} else {
		fmt.Printf("  \033[91m✗\033[0m %s  <<< FAILED\n", name)
	}
}

func register(phone string) (token, userID string) {
	body := fmt.Sprintf(`{"phone_number":"%s","password":"test","identity_public_key":"pk"}`, phone)
	resp, _ := http.Post("http://localhost:8080/v1/auth/register", "application/json", strings.NewReader(body))
	if resp == nil {
		return "", ""
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	var r map[string]interface{}
	json.Unmarshal(data, &r)
	t, _ := r["token"].(string)
	u, _ := r["user_id"].(string)
	return t, u
}

func wsConnect(token string) (*websocket.Conn, error) {
	u := url.URL{Scheme: "ws", Host: "localhost:8080", Path: "/ws"}
	c, _, err := websocket.DefaultDialer.Dial(u.String(), http.Header{"Authorization": {"Bearer " + token}})
	return c, err
}

func main() {
	fmt.Printf("\n\033[1m=== WebSocket Signaling E2E Test ===\033[0m\n\n")

	exec.Command("pkill", "-f", "myphone-server").Run()
	time.Sleep(500 * time.Millisecond)

	srv := exec.Command("/tmp/myphone-server")
	srv.Env = append(os.Environ(),
		"DATABASE_URL=postgres://myphone:myphone@localhost:5432/myphone?sslmode=disable",
		"REDIS_ADDR=localhost:6379",
	)
	srv.Start()
	defer srv.Process.Kill()
	time.Sleep(1500 * time.Millisecond)

	resp, _ := http.Get("http://localhost:8080/health")
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	ok("Server health", strings.TrimSpace(string(b)) == "ok")

	fmt.Println("\n>>> Registering...")
	n := time.Now().Unix()
	aT, aID := register(fmt.Sprintf("+86000%d", n))
	bT, bID := register(fmt.Sprintf("+86001%d", n+1))
	ok("Alice registered", aT != "")
	ok("Bob registered", bT != "")
	fmt.Printf("  Alice=%s\n  Bob=%s\n", aID, bID)

	fmt.Println("\n>>> WebSocket connect...")
	aws, _ := wsConnect(aT)
	bws, _ := wsConnect(bT)
	ok("Alice WS open", aws != nil)
	ok("Bob WS open", bws != nil)
	if aws == nil || bws == nil {
		fmt.Println("\033[91mCannot proceed without WS\033[0m")
		os.Exit(1)
	}
	defer aws.Close()
	defer bws.Close()
	time.Sleep(500 * time.Millisecond)

	send := func(ws *websocket.Conn, m map[string]interface{}) {
		d, _ := json.Marshal(m)
		ws.WriteMessage(websocket.TextMessage, d)
	}
	recv := func(ws *websocket.Conn, dur time.Duration) map[string]interface{} {
		ws.SetReadDeadline(time.Now().Add(dur))
		_, data, err := ws.ReadMessage()
		if err != nil {
			return nil
		}
		var r map[string]interface{}
		json.Unmarshal(data, &r)
		return r
	}

	// 1. Offer Alice → Bob
	fmt.Println("\n>>> Offer (Alice→Bob)")
	send(aws, map[string]interface{}{
		"type": "offer", "call_id": "c1",
		"from_user_id": aID, "to_user_id": bID,
		"payload": map[string]string{"sdp": "v=0 o=alice"},
	})
	rx := recv(bws, 5*time.Second)
	ok("Bob got offer type", rx != nil && rx["type"] == "offer")
	ok("Bob got call_id c1", rx != nil && rx["call_id"] == "c1")

	// 2. Answer Bob → Alice
	fmt.Println("\n>>> Answer (Bob→Alice)")
	send(bws, map[string]interface{}{
		"type": "answer", "call_id": "c1",
		"from_user_id": bID, "to_user_id": aID,
		"payload": map[string]string{"sdp": "v=0 o=bob"},
	})
	rx = recv(aws, 5*time.Second)
	ok("Alice got answer type", rx != nil && rx["type"] == "answer")
	ok("Alice got call_id c1", rx != nil && rx["call_id"] == "c1")

	// 3. ICE exchange
	fmt.Println("\n>>> ICE (Alice→Bob→Alice)")
	send(aws, map[string]interface{}{
		"type": "iceCandidate", "call_id": "c1",
		"from_user_id": aID, "to_user_id": bID,
		"payload": map[string]interface{}{
			"candidate": "udp 10.0.0.1 12345 host",
			"sdp_mid": "0", "sdp_m_line_index": 0,
		},
	})
	rx = recv(bws, 5*time.Second)
	ok("Bob got ICE", rx != nil && rx["type"] == "iceCandidate")

	send(bws, map[string]interface{}{
		"type": "iceCandidate", "call_id": "c1",
		"from_user_id": bID, "to_user_id": aID,
		"payload": map[string]interface{}{
			"candidate": "udp 192.168.1.1 54321 srflx",
			"sdp_mid": "0", "sdp_m_line_index": 0,
		},
	})
	rx = recv(aws, 5*time.Second)
	ok("Alice got ICE", rx != nil && rx["type"] == "iceCandidate")

	// 4. Hangup
	fmt.Println("\n>>> Hangup (Alice→Bob)")
	send(aws, map[string]interface{}{
		"type": "hangup", "call_id": "c1",
		"from_user_id": aID, "to_user_id": bID,
	})
	rx = recv(bws, 5*time.Second)
	ok("Bob got hangup", rx != nil && rx["type"] == "hangup")

	// 5. Negative: ghost user
	fmt.Println("\n>>> Negative: ghost user")
	send(aws, map[string]interface{}{
		"type": "offer", "call_id": "ghost",
		"from_user_id": aID, "to_user_id": "nonexistent_999",
	})
	rx = recv(bws, 2*time.Second)
	ok("Ghost NOT delivered", rx == nil)

	fmt.Printf("\n%s\n", strings.Repeat("=", 50))
	fmt.Printf(" %d/%d passed %s\n", passed, total,
		map[bool]string{true: "\033[92mALL GREEN\033[0m", false: fmt.Sprintf("\033[91m%d FAILURES\033[0m", total-passed)}[passed == total])
	fmt.Printf("%s\n", strings.Repeat("=", 50))

	if passed != total {
		os.Exit(1)
	}
}
