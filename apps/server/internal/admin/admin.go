package admin

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"runtime"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/myphone/server/internal/models"
	"golang.org/x/crypto/bcrypt"
)

type Handler struct {
	db        *models.DB
	hubStats  func() map[string]interface{}
	startTime time.Time
}

func NewHandler(db *models.DB, hubStats func() map[string]interface{}) *Handler {
	return &Handler{db: db, hubStats: hubStats, startTime: time.Now()}
}

func (h *Handler) RegisterRoutes(r chi.Router) {
	r.Get("/admin", h.Dashboard)
	r.Get("/admin/", h.Dashboard)

	// API: Dashboard
	r.Get("/admin/api/dashboard", h.APIDashboard)

	// API: Users
	r.Get("/admin/api/users", h.APIUsers)
	r.Post("/admin/api/users/create", h.APICreateUser)
	r.Get("/admin/api/users/{userID}", h.APIUserDetail)
	r.Post("/admin/api/users/{userID}/disable", h.APIDisableUser)
	r.Post("/admin/api/users/{userID}/enable", h.APIEnableUser)
	r.Post("/admin/api/users/{userID}/delete", h.APIDeleteUser)

	// API: Connections
	r.Get("/admin/api/connections", h.APIConnections)

	// API: CDR
	r.Get("/admin/api/cdr", h.APICDR)

	// API: Keys
	r.Get("/admin/api/key-status", h.APIKeyStatus)

	// API: Config
	r.Get("/admin/api/server-info", h.APIServerInfo)
}

// ======== Pages ========

func (h *Handler) Dashboard(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, adminHTML)
}

// ======== Dashboard API ========

func (h *Handler) APIDashboard(w http.ResponseWriter, r *http.Request) {
	var totalUsers, activeUsers, disabledUsers, totalKeys, unusedKeys int
	h.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&totalUsers)
	h.db.QueryRow("SELECT COUNT(*) FROM users WHERE status='active'").Scan(&activeUsers)
	h.db.QueryRow("SELECT COUNT(*) FROM users WHERE status='disabled'").Scan(&disabledUsers)
	h.db.QueryRow("SELECT COUNT(*) FROM pre_keys").Scan(&totalKeys)
	h.db.QueryRow("SELECT COUNT(*) FROM pre_keys WHERE is_used=false").Scan(&unusedKeys)

	var todayCalls, totalCDR int
	h.db.QueryRow("SELECT COUNT(*) FROM cdr WHERE started_at >= CURRENT_DATE").Scan(&todayCalls)
	h.db.QueryRow("SELECT COUNT(*) FROM cdr").Scan(&totalCDR)

	hub := h.hubStats()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"total_users":       totalUsers,
		"active_users":      activeUsers,
		"disabled_users":    disabledUsers,
		"total_prekeys":     totalKeys,
		"unused_prekeys":    unusedKeys,
		"today_calls":       todayCalls,
		"total_cdr":         totalCDR,
		"online_ws":         hub["online_users"],
		"calls_active":      hub["calls_active"],
		"calls_completed":   hub["calls_completed"],
		"signaling_messages": hub["total_messages"],
		"server_uptime":     time.Since(h.startTime).Round(time.Second).String(),
		"ws_uptime":         hub["uptime"],
		"go_routines":       runtime.NumGoroutine(),
		"mem_alloc_mb":      ms.Alloc / 1024 / 1024,
		"mem_total_mb":      ms.Sys / 1024 / 1024,
	})
}

// ======== Users API ========

func (h *Handler) APIUsers(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	search := r.URL.Query().Get("search")
	status := r.URL.Query().Get("status")
	if page < 1 { page = 1 }
	limit := 20
	offset := (page - 1) * limit

	where := "WHERE 1=1"
	args := []interface{}{}
	argIdx := 1
	if status == "active" || status == "disabled" {
		where += fmt.Sprintf(" AND status=$%d", argIdx)
		args = append(args, status)
		argIdx++
	}
	if search != "" {
		where += fmt.Sprintf(" AND (id ILIKE $%d OR phone_hash ILIKE $%d)", argIdx, argIdx+1)
		args = append(args, "%"+search+"%", "%"+search+"%")
		argIdx += 2
	}

	var total int
	h.db.QueryRow("SELECT COUNT(*) FROM users "+where, args...).Scan(&total)

	rows, _ := h.db.Query(
		"SELECT id, phone_hash, display_name, status, created_at, last_seen FROM users "+where+" ORDER BY created_at DESC LIMIT $"+strconv.Itoa(argIdx)+" OFFSET $"+strconv.Itoa(argIdx+1),
		append(args, limit, offset)...,
	)
	defer rows.Close()

	type UR struct {
		ID          string     `json:"id"`
		PhoneHash   string     `json:"phone_hash"`
		DisplayName string     `json:"display_name"`
		Status      string     `json:"status"`
		CreatedAt   *time.Time `json:"created_at"`
		LastSeen    *time.Time `json:"last_seen"`
	}
	users := []UR{}
	for rows.Next() {
		var u UR
		rows.Scan(&u.ID, &u.PhoneHash, &u.DisplayName, &u.Status, &u.CreatedAt, &u.LastSeen)
		users = append(users, u)
	}
	json.NewEncoder(w).Encode(map[string]interface{}{
		"users": users, "total": total, "page": page, "total_pages": (total+limit-1)/limit,
	})
}

func (h *Handler) APICreateUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PhoneNumber       string `json:"phone_number"`
		Password          string `json:"password"`
		DisplayName       string `json:"display_name"`
		IdentityPublicKey string `json:"identity_public_key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}
	if req.PhoneNumber == "" || req.Password == "" {
		http.Error(w, `{"error":"phone_number and password required"}`, http.StatusBadRequest)
		return
	}
	if req.DisplayName == "" {
		req.DisplayName = req.PhoneNumber
	}
	if req.IdentityPublicKey == "" {
		req.IdentityPublicKey = "admin-created"
	}

	// ★密码必须与 /v1/auth/login 的校验方式一致（bcrypt）。
	//   之前这里用 SHA256 存储，导致管理员创建的用户永远无法登录（登录走 bcrypt 校验）。
	passwordHash, _ := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	_, err := h.db.Exec(
		`INSERT INTO users (id, phone_hash, display_name, identity_public_key, password_hash) VALUES ($1,$2,$3,$4,$5)`,
		generateID(), hashPhone(req.PhoneNumber), req.DisplayName,
		req.IdentityPublicKey, string(passwordHash),
	)
	if err != nil {
		http.Error(w, `{"error":"user already exists"}`, http.StatusConflict)
		return
	}
	h.logAdmin("create_user", req.PhoneNumber)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (h *Handler) APIUserDetail(w http.ResponseWriter, r *http.Request) {
	uid := chi.URLParam(r, "userID")
	var displayName, phoneHash, status string
	var createdAt, lastSeen time.Time
	h.db.QueryRow("SELECT display_name, phone_hash, status, created_at, last_seen FROM users WHERE id=$1", uid).
		Scan(&displayName, &phoneHash, &status, &createdAt, &lastSeen)

	var deviceCount int
	h.db.QueryRow("SELECT COUNT(*) FROM pre_keys WHERE user_id=$1", uid).Scan(&deviceCount)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"id": uid, "display_name": displayName, "phone_hash": phoneHash,
		"status": status, "created_at": createdAt, "last_seen": lastSeen,
		"prekey_count": deviceCount,
	})
}

func (h *Handler) APIDisableUser(w http.ResponseWriter, r *http.Request) {
	uid := chi.URLParam(r, "userID")
	h.db.Exec("UPDATE users SET status='disabled' WHERE id=$1", uid)
	h.logAdmin("disable_user", uid)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (h *Handler) APIEnableUser(w http.ResponseWriter, r *http.Request) {
	uid := chi.URLParam(r, "userID")
	h.db.Exec("UPDATE users SET status='active' WHERE id=$1", uid)
	h.logAdmin("enable_user", uid)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// APIDeleteUser 永久删除用户及其预密钥（不可恢复）。
// pre_keys / signed_pre_keys 有外键 REFERENCES users(id) 且无 CASCADE，
// 必须先删子表再删 users；cdr（无外键）保留作为通话历史。
// 注意：删除后该用户旧 token 虽未过期，但预密钥上传会被外键拒绝、bundle 查不到，
// 实际已无法正常使用。
func (h *Handler) APIDeleteUser(w http.ResponseWriter, r *http.Request) {
	uid := chi.URLParam(r, "userID")
	tx, err := h.db.Begin()
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`DELETE FROM pre_keys WHERE user_id=$1`, uid); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	if _, err := tx.Exec(`DELETE FROM signed_pre_keys WHERE user_id=$1`, uid); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	res, err := tx.Exec(`DELETE FROM users WHERE id=$1`, uid)
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		return
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	h.logAdmin("delete_user", uid)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// ======== Connections API ========

func (h *Handler) APIConnections(w http.ResponseWriter, r *http.Request) {
	hub := h.hubStats()
	users, _ := hub["users"].([]map[string]interface{})
	if users == nil { users = []map[string]interface{}{} }
	json.NewEncoder(w).Encode(map[string]interface{}{
		"connections": users, "count": len(users),
	})
}

// ======== CDR API ========

func (h *Handler) APICDR(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	if page < 1 { page = 1 }
	limit := 30
	offset := (page - 1) * limit

	var total int
	h.db.QueryRow("SELECT COUNT(*) FROM cdr").Scan(&total)

	rows, _ := h.db.Query(`SELECT id, call_id, caller_id, callee_id, direction, status,
		started_at, ended_at, duration_secs, codec, avg_bitrate_kbps, packet_loss_pct, rtt_ms
		FROM cdr ORDER BY started_at DESC LIMIT $1 OFFSET $2`, limit, offset)
	defer rows.Close()

	type CDR struct {
		ID           int        `json:"id"`
		CallID       string     `json:"call_id"`
		CallerID     string     `json:"caller_id"`
		CalleeID     string     `json:"callee_id"`
		Direction    string     `json:"direction"`
		Status       string     `json:"status"`
		StartedAt    *time.Time `json:"started_at"`
		EndedAt      *time.Time `json:"ended_at"`
		DurationSecs int        `json:"duration_secs"`
		AvgBitrate   int        `json:"avg_bitrate"`
		Codec        string     `json:"codec"`
		PacketLoss   float64    `json:"packet_loss"`
		RTT          float64    `json:"rtt"`
	}
	cdrs := []CDR{}
	for rows.Next() {
		var c CDR
		rows.Scan(&c.ID, &c.CallID, &c.CallerID, &c.CalleeID, &c.Direction, &c.Status,
			&c.StartedAt, &c.EndedAt, &c.DurationSecs, &c.Codec, &c.AvgBitrate, &c.PacketLoss, &c.RTT)
		cdrs = append(cdrs, c)
	}
	json.NewEncoder(w).Encode(map[string]interface{}{
		"cdrs": cdrs, "total": total, "page": page, "total_pages": (total+limit-1)/limit,
	})
}

// ======== Key Status API ========

func (h *Handler) APIKeyStatus(w http.ResponseWriter, r *http.Request) {
	var totalPrekeys, unusedPrekeys int
	h.db.QueryRow("SELECT COUNT(*), SUM(CASE WHEN is_used=false THEN 1 ELSE 0 END) FROM pre_keys").Scan(&totalPrekeys, &unusedPrekeys)

	var usersOutput []map[string]interface{}
	rows, _ := h.db.Query(`SELECT u.id, u.display_name,
		(SELECT COUNT(*) FROM pre_keys p WHERE p.user_id=u.id AND p.is_used=false) as unused,
		(SELECT COUNT(*) FROM pre_keys p WHERE p.user_id=u.id) as total
		FROM users u WHERE u.status='active' ORDER BY unused ASC LIMIT 50`)
	defer rows.Close()

	lowKeyUsers := 0
	for rows.Next() {
		var uid, name string
		var unused, total int
		rows.Scan(&uid, &name, &unused, &total)
		if unused < 10 { lowKeyUsers++ }
		usersOutput = append(usersOutput, map[string]interface{}{
			"user_id": uid, "display_name": name,
			"unused": unused, "total": total,
			"warning": unused < 10,
		})
	}
	json.NewEncoder(w).Encode(map[string]interface{}{
		"total_prekeys":   totalPrekeys,
		"unused_prekeys":  unusedPrekeys,
		"low_key_users":   lowKeyUsers,
		"user_key_detail": usersOutput,
	})
}

// ======== Server Info API ========

func (h *Handler) APIServerInfo(w http.ResponseWriter, r *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"go_version":    runtime.Version(),
		"num_cpu":       runtime.NumCPU(),
		"num_goroutine": runtime.NumGoroutine(),
		"mem_alloc_mb":  ms.Alloc / 1024 / 1024,
		"mem_sys_mb":    ms.Sys / 1024 / 1024,
		"gc_count":      ms.NumGC,
		"server_uptime": time.Since(h.startTime).Round(time.Second).String(),
		"started_at":    h.startTime.Format(time.RFC3339),
	})
}

func (h *Handler) logAdmin(action, detail string) {
	h.db.Exec("INSERT INTO admin_logs (action, detail, operator) VALUES ($1,$2,'admin')", action, detail)
}

// generateID 生成 16 字节随机 ID（输出 32 位 hex）。
// ★改为 crypto/rand 真随机：旧实现基于时间戳派生，可预测且同纳秒会碰撞。
//   格式与旧实现一致（32 位 hex），对存量/下游完全透明。
func generateID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand 失败属致命环境错误；退回到时间戳派生（极罕见），
		// 避免创建用户流程直接报错。
		return fmt.Sprintf("%x", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

func hashPhone(phone string) string {
	h := sha256.Sum256([]byte("myphone-salt:" + phone))
	return hex.EncodeToString(h[:])
}

// ======== Admin HTML SPA ========

const adminHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MyPhone Admin</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1923;color:#e0e6ed;display:flex;min-height:100vh}
nav{width:220px;background:#1a2836;padding:20px 0;flex-shrink:0;display:flex;flex-direction:column}
nav h2{padding:0 20px 24px;font-size:18px;color:#1a73e8}
nav a{display:block;padding:12px 20px;color:#8899a6;text-decoration:none;font-size:14px;transition:.2s;cursor:pointer}
nav a:hover,nav a.active{color:#e0e6ed;background:rgba(26,115,232,.15);border-left:3px solid #1a73e8}
nav .nav-spacer{flex:1}
main{flex:1;padding:28px 32px;overflow-y:auto}
h1{font-size:22px;margin-bottom:20px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:16px;margin-bottom:28px}
.card{background:#1a2836;border-radius:10px;padding:20px}
.card .label{font-size:12px;color:#8899a6;margin-bottom:6px;text-transform:uppercase;letter-spacing:.5px}
.card .value{font-size:28px;font-weight:700;color:#1a73e8}
.card .value.green{color:#34a853}.card .value.red{color:#ea4335}.card .value.yellow{color:#fbbc04}
table{width:100%;border-collapse:collapse;background:#1a2836;border-radius:10px;overflow:hidden;font-size:13px}
th{text-align:left;padding:10px 14px;font-size:11px;color:#8899a6;text-transform:uppercase;border-bottom:1px solid #253545}
td{padding:9px 14px;border-bottom:1px solid #253545;max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
td.mono{white-space:normal;word-break:break-all;max-width:300px}
tr:last-child td{border-bottom:none}
tr:hover{background:rgba(26,115,232,.06)}
.badge{display:inline-block;padding:2px 10px;border-radius:10px;font-size:11px;font-weight:600}
.badge.online{background:rgba(52,168,83,.2);color:#34a853}
.badge.offline{background:rgba(154,160,166,.15);color:#8899a6}
.badge.warn{background:rgba(251,188,4,.15);color:#fbbc04}
.btn{padding:6px 16px;border-radius:6px;border:none;cursor:pointer;font-size:12px;font-weight:600;transition:.2s}
.btn.danger{background:rgba(234,67,53,.15);color:#ea4335}.btn.danger:hover{background:rgba(234,67,53,.3)}
.btn.primary{background:rgba(26,115,232,.15);color:#1a73e8}.btn.primary:hover{background:rgba(26,115,232,.3)}
.btn.sm{padding:3px 10px;font-size:11px}
pre{background:#0a1118;padding:16px;border-radius:8px;font-size:12px;overflow-x:auto;max-height:400px}
.tab{display:none}.tab.active{display:block}
.refresh{color:#8899a6;font-size:12px;float:right}
.toolbar{display:flex;gap:12px;margin-bottom:16px;align-items:center}
.toolbar input,.toolbar select{padding:6px 12px;border-radius:6px;border:1px solid #253545;background:#1a2836;color:#e0e6ed;font-size:12px;outline:none}
.toolbar input:focus{border-color:#1a73e8}
.pagination{display:flex;gap:8px;margin-top:12px;justify-content:center;align-items:center}
.pagination button{padding:6px 14px;border-radius:6px;border:1px solid #253545;background:#1a2836;color:#e0e6ed;cursor:pointer;font-size:12px}
.pagination button:hover{background:#253545}
.pagination span{color:#8899a6;font-size:12px}
.mono{font-family:monospace;font-size:11px}
.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.7);z-index:100;justify-content:center;align-items:center}
.modal.active{display:flex}
.modal-content{background:#1a2836;border-radius:12px;padding:24px;min-width:400px;max-width:500px}
.modal-content h3{margin-bottom:16px}
.modal-content .row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #253545;font-size:13px}
.toast{position:fixed;top:20px;right:20px;padding:12px 24px;border-radius:8px;font-size:13px;z-index:200;opacity:0;transition:opacity .3s}
.toast.show{opacity:1}.toast.success{background:#34a853;color:#fff}.toast.error{background:#ea4335;color:#fff}
</style>
</head>
<body>
<nav>
<h2>🔒 MyPhone Admin</h2>
<a href="#dashboard" class="active" onclick="switchTab('dashboard')">📊 系统概览</a>
<a href="#users" onclick="switchTab('users')">👥 用户管理</a>
<a href="#connections" onclick="switchTab('connections')">🟢 实时连接</a>
<a href="#cdr" onclick="switchTab('cdr')">📞 通话记录</a>
<a href="#keys" onclick="switchTab('keys')">🔑 密钥管理</a>
<a href="#server" onclick="switchTab('server')">⚙️ 服务状态</a>
</nav>

<main>
<!-- Dashboard -->
<div id="tab-dashboard" class="tab active">
<h1>系统概览 <span class="refresh" id="refresh-db"></span></h1>
<div class="cards" id="db-cards"></div>
</div>

<!-- Users -->
<div id="tab-users" class="tab">
<h1>用户管理 <span class="refresh" id="refresh-us"></span></h1>
<div class="toolbar">
  <input type="text" id="us-search" placeholder="搜索 ID / 手机号哈希..." onkeydown="if(event.key==='Enter')loadUsers()">
  <select id="us-status" onchange="loadUsers()"><option value="">全部状态</option><option value="active">已启用</option><option value="disabled">已禁用</option></select>
  <button class="btn primary sm" onclick="loadUsers()">搜索</button>
  <button class="btn primary sm" onclick="showCreateForm()">＋ 添加用户</button>
</div>
<table><thead><tr><th>用户ID</th><th>状态</th><th>注册时间</th><th>操作</th></tr></thead><tbody id="us-table"></tbody></table>
<div class="pagination" id="us-pager"></div>
</div>

<!-- Connections -->
<div id="tab-connections" class="tab">
<h1>实时 WebSocket 连接 <span class="refresh" id="refresh-cn"></span></h1>
<table><thead><tr><th>用户ID</th><th>连接时间</th><th>持续时长</th></tr></thead><tbody id="cn-table"></tbody></table>
</div>

<!-- CDR -->
<div id="tab-cdr" class="tab">
<h1>通话记录 (CDR) <span class="refresh" id="refresh-cdr"></span></h1>
<table><thead><tr><th>时间</th><th>主叫</th><th>被叫</th><th>时长</th><th>编码</th><th>码率</th><th>丢包</th><th>RTT</th><th>状态</th></tr></thead><tbody id="cdr-table"></tbody></table>
<div class="pagination" id="cdr-pager"></div>
</div>

<!-- Keys -->
<div id="tab-keys" class="tab">
<h1>密钥管理 <span class="refresh" id="refresh-kp"></span></h1>
<div class="cards" id="kp-cards"></div>
<table style="margin-top:20px"><thead><tr><th>用户ID</th><th>名称</th><th>可用PreKey</th><th>总PreKey</th><th>状态</th></tr></thead><tbody id="kp-table"></tbody></table>
</div>

<!-- Server Info -->
<div id="tab-server" class="tab">
<h1>服务状态 <span class="refresh" id="refresh-si"></span></h1>
<pre id="si-pre"></pre>
</div>
</main>

<div class="modal" id="user-modal">
<div class="modal-content" id="user-modal-content"></div>
</div>
<div class="toast" id="toast"></div>

<script>
let usPage=1,cdrPage=1,currentTab='dashboard';

function switchTab(t){
 document.querySelectorAll('.tab').forEach(e=>e.classList.remove('active'));
 document.getElementById('tab-'+t).classList.add('active');
 document.querySelectorAll('nav a').forEach(a=>a.classList.remove('active'));
 document.querySelector('a[href="#'+t+'"]').classList.add('active');
 currentTab=t;
 t==='dashboard'?loadDashboard():t==='users'?loadUsers():t==='connections'?loadConnections():t==='cdr'?loadCDR():t==='keys'?loadKeyStatus():loadServerInfo();
}

async function fetchJSON(url){const r=await fetch(url);return r.json()}

// === Dashboard ===
async function loadDashboard(){
 const d=await fetchJSON('/admin/api/dashboard');
 document.getElementById('db-cards').innerHTML=
  '<div class="card"><div class="label">注册用户</div><div class="value">'+d.total_users+'</div></div>'+
  '<div class="card"><div class="label">已启用</div><div class="value green">'+d.active_users+'</div></div>'+
  '<div class="card"><div class="label">已禁用</div><div class="value red">'+d.disabled_users+'</div></div>'+
  '<div class="card"><div class="label">在线 WS</div><div class="value green">'+d.online_ws+'</div></div>'+
  '<div class="card"><div class="label">活跃通话</div><div class="value yellow">'+d.calls_active+'</div></div>'+
  '<div class="card"><div class="label">今日通话</div><div class="value">'+d.today_calls+'</div></div>'+
  '<div class="card"><div class="label">累计通话</div><div class="value">'+d.total_cdr+'</div></div>'+
  '<div class="card"><div class="label">信令消息数</div><div class="value">'+d.signaling_messages+'</div></div>'+
  '<div class="card"><div class="label">可用 PreKey</div><div class="value">'+d.unused_prekeys+'</div></div>'+
  '<div class="card"><div class="label">Go 协程数</div><div class="value">'+d.go_routines+'</div></div>'+
  '<div class="card"><div class="label">内存占用</div><div class="value" style="font-size:20px">'+d.mem_alloc_mb+' MB</div></div>'+
  '<div class="card"><div class="label">运行时间</div><div class="value" style="font-size:20px">'+d.server_uptime+'</div></div>';
 document.getElementById('refresh-db').textContent='刷新 '+new Date().toLocaleTimeString();
}

// === Users ===
async function loadUsers(p){
 if(p) usPage=p;
 const s=document.getElementById('us-search').value;
 const st=document.getElementById('us-status').value;
 const d=await fetchJSON('/admin/api/users?page='+usPage+'&search='+encodeURIComponent(s)+'&status='+st);
 let rows='';
 d.users.forEach(u=>{
  rows+='<tr><td class="mono" title="'+u.id+'">'+u.id+'</td>'+
  '<td><span class="badge '+(u.status==='active'?'online':'offline')+'">'+(u.status==='active'?'启用':'禁用')+'</span></td>'+
  '<td>'+(u.created_at?new Date(u.created_at).toLocaleString():'-')+'</td>'+
  '<td><button class="btn sm" onclick="showUserDetail(\''+u.id+'\')">详情</button> '+
  (u.status==='active'?'<button class="btn sm danger" onclick="disableUser(\''+u.id+'\')">禁用</button>':'<button class="btn sm primary" onclick="enableUser(\''+u.id+'\')">启用</button>')+
  ' <button class="btn sm danger" onclick="deleteUser(\''+u.id+'\')">删除</button></td></tr>';
 });
 document.getElementById('us-table').innerHTML=rows||'<tr><td colspan="4" style="text-align:center;color:#8899a6;padding:20px">无匹配用户</td></tr>';
 let pager='';
 if(d.page>1) pager+='<button onclick="loadUsers('+(d.page-1)+')">上一页</button>';
 pager+='<span>第 '+d.page+' / '+d.total_pages+' 页 (共 '+d.total+' 条)</span>';
 if(d.page<d.total_pages) pager+='<button onclick="loadUsers('+(d.page+1)+')">下一页</button>';
 document.getElementById('us-pager').innerHTML=pager;
 document.getElementById('refresh-us').textContent='刷新 '+new Date().toLocaleTimeString();
}

async function showUserDetail(uid){
 const d=await fetchJSON('/admin/api/users/'+uid);
 document.getElementById('user-modal-content').innerHTML=
  '<h3>用户详情</h3>'+
  '<div class="row"><span>ID</span><span class="mono">'+d.id+'</span></div>'+
  '<div class="row"><span>名称</span><span>'+d.display_name+'</span></div>'+
  '<div class="row"><span>手机号哈希</span><span class="mono">'+d.phone_hash+'</span></div>'+
  '<div class="row"><span>状态</span><span>'+d.status+'</span></div>'+
  '<div class="row"><span>注册时间</span><span>'+new Date(d.created_at).toLocaleString()+'</span></div>'+
  '<div class="row"><span>最后在线</span><span>'+new Date(d.last_seen).toLocaleString()+'</span></div>'+
  '<div class="row"><span>PreKey 数量</span><span>'+d.prekey_count+'</span></div>'+
  '<div style="margin-top:16px;text-align:right"><button class="btn sm" onclick="closeModal()">关闭</button></div>';
 document.getElementById('user-modal').classList.add('active');
}
function closeModal(){document.getElementById('user-modal').classList.remove('active');document.getElementById('user-modal').onclick=null}
document.getElementById('user-modal').onclick=function(e){if(e.target===this)closeModal()}
function showCreateForm(){
 document.getElementById('user-modal-content').innerHTML=
  '<h3>添加用户</h3>'+
  '<div style="display:flex;flex-direction:column;gap:12px">'+
  '<div><label style="font-size:12px;color:#8899a6">手机号</label><input id="cu-phone" style="width:100%;padding:8px 12px;border-radius:6px;border:1px solid #253545;background:#0f1923;color:#e0e6ed;font-size:14px;margin-top:4px" placeholder="+8613800138000"></div>'+
  '<div><label style="font-size:12px;color:#8899a6">密码</label><input id="cu-pw" type="password" style="width:100%;padding:8px 12px;border-radius:6px;border:1px solid #253545;background:#0f1923;color:#e0e6ed;font-size:14px;margin-top:4px" placeholder="至少6位"></div>'+
  '<div><label style="font-size:12px;color:#8899a6">显示名称 (可选)</label><input id="cu-name" style="width:100%;padding:8px 12px;border-radius:6px;border:1px solid #253545;background:#0f1923;color:#e0e6ed;font-size:14px;margin-top:4px" placeholder="张三"></div>'+
  '</div>'+
  '<div style="margin-top:16px;display:flex;gap:8px;justify-content:flex-end">'+
  '<button class="btn sm" onclick="closeModal()">取消</button>'+
  '<button class="btn sm primary" onclick="createUser()">创建</button></div>';
 document.getElementById('user-modal').classList.add('active');
}
async function createUser(){
 const phone=document.getElementById('cu-phone').value.trim();
 const pw=document.getElementById('cu-pw').value;
 const name=document.getElementById('cu-name').value.trim();
 if(!phone||!pw){toastShow('手机号和密码必填','error');return}
 const r=await fetch('/admin/api/users/create',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({phone_number:phone,password:pw,display_name:name})});
 if(r.ok){toastShow('用户创建成功','success');closeModal();loadUsers()}else{const e=await r.json();toastShow('创建失败: '+e.error,'error')}
}

async function disableUser(uid){
 if(!confirm('确认禁用用户 '+uid+' ?')) return;
 await fetch('/admin/api/users/'+uid+'/disable',{method:'POST'});
 toastShow('已禁用: '+uid,'success'); loadUsers(usPage);
}
async function enableUser(uid){
 await fetch('/admin/api/users/'+uid+'/enable',{method:'POST'});
 toastShow('已启用: '+uid,'success'); loadUsers(usPage);
}
async function deleteUser(uid){
 if(!confirm('确认永久删除用户 '+uid+' ?\n将同时删除其所有预密钥,此操作不可恢复!')) return;
 const r=await fetch('/admin/api/users/'+uid+'/delete',{method:'POST'});
 if(r.ok){toastShow('已删除: '+uid,'success'); loadUsers(usPage);}
 else{const e=await r.json(); toastShow('删除失败: '+e.error,'error');}
}

// === Connections ===
async function loadConnections(){
 const d=await fetchJSON('/admin/api/connections');
 let rows='';
 (d.connections||[]).forEach(c=>{
  rows+='<tr><td class="mono" title="'+c.user_id+'">'+c.user_id+'</td>'+
  '<td>'+c.connected+'</td><td><span class="badge online">'+c.uptime+'</span></td></tr>';
 });
 document.getElementById('cn-table').innerHTML=rows||'<tr><td colspan="3" style="text-align:center;color:#8899a6;padding:20px">暂无在线连接</td></tr>';
 document.getElementById('refresh-cn').textContent='刷新 '+new Date().toLocaleTimeString()+' ('+(d.count||0)+' 在线)';
}

// === CDR ===
async function loadCDR(p){
 if(p) cdrPage=p;
 const d=await fetchJSON('/admin/api/cdr?page='+cdrPage);
 let rows='';
 d.cdrs.forEach(c=>{
  const t=c.started_at?new Date(c.started_at).toLocaleString():'-';
  const m=Math.floor(c.duration_secs/60)+':'+String(c.duration_secs%60).padStart(2,'0');
  rows+='<tr><td>'+t+'</td>'+
  '<td class="mono" title="'+c.caller_id+'">'+c.caller_id.substring(0,8)+'...</td>'+
  '<td class="mono" title="'+c.callee_id+'">'+c.callee_id.substring(0,8)+'...</td>'+
  '<td>'+m+'</td><td>'+c.codec+'</td><td>'+(c.avg_bitrate||'-')+'</td>'+
  '<td>'+(c.packet_loss>0?c.packet_loss.toFixed(1)+'%':'-')+'</td>'+
  '<td>'+(c.rtt>0?c.rtt.toFixed(0)+'ms':'-')+'</td>'+
  '<td><span class="badge '+(c.status==='answered'?'online':'offline')+'">'+c.status+'</span></td></tr>';
 });
 document.getElementById('cdr-table').innerHTML=rows||'<tr><td colspan="9" style="text-align:center;color:#8899a6;padding:20px">暂无通话记录</td></tr>';
 let pager='';
 if(d.page>1) pager+='<button onclick="loadCDR('+(d.page-1)+')">上一页</button>';
 pager+='<span>第 '+d.page+' / '+d.total_pages+' 页 (共 '+d.total+' 条)</span>';
 if(d.page<d.total_pages) pager+='<button onclick="loadCDR('+(d.page+1)+')">下一页</button>';
 document.getElementById('cdr-pager').innerHTML=pager;
 document.getElementById('refresh-cdr').textContent='刷新 '+new Date().toLocaleTimeString();
}

// === Key Status ===
async function loadKeyStatus(){
 const d=await fetchJSON('/admin/api/key-status');
 document.getElementById('kp-cards').innerHTML=
  '<div class="card"><div class="label">PreKey 总量</div><div class="value">'+d.total_prekeys+'</div></div>'+
  '<div class="card"><div class="label">可用 PreKey</div><div class="value green">'+d.unused_prekeys+'</div></div>'+
  '<div class="card"><div class="label">低库存用户</div><div class="value '+(d.low_key_users>0?'red':'green')+'">'+d.low_key_users+'</div></div>';
 let rows='';
 (d.user_key_detail||[]).forEach(u=>{
  rows+='<tr><td class="mono">'+u.user_id+'</td>'+
  '<td>'+u.display_name+'</td><td>'+u.unused+'</td><td>'+u.total+'</td>'+
  '<td>'+(u.warning?'<span class="badge warn">⚠ 不足</span>':'<span class="badge online">正常</span>')+'</td></tr>';
 });
 document.getElementById('kp-table').innerHTML=rows||'<tr><td colspan="5" style="text-align:center;color:#8899a6;padding:20px">无数据</td></tr>';
 document.getElementById('refresh-kp').textContent='刷新 '+new Date().toLocaleTimeString();
}

// === Server Info ===
async function loadServerInfo(){
 const d=await fetchJSON('/admin/api/server-info');
 document.getElementById('si-pre').textContent=JSON.stringify(d,null,2);
 document.getElementById('refresh-si').textContent='刷新 '+new Date().toLocaleTimeString();
}

function toastShow(msg,type){
 const t=document.getElementById('toast');
 t.textContent=msg; t.className='toast '+type+' show';
 setTimeout(()=>t.classList.remove('show'),2500);
}

setInterval(()=>{
 if(currentTab==='dashboard') loadDashboard();
 else if(currentTab==='connections') loadConnections();
},5000);
loadDashboard();
</script>
</body>
</html>`
