package admin

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/myphone/server/internal/models"
)

type Handler struct {
	db        *models.DB
	hubStats  func() map[string]interface{}
	startTime time.Time
}

func NewHandler(db *models.DB, hubStats func() map[string]interface{}) *Handler {
	return &Handler{db: db, hubStats: hubStats, startTime: time.Now()}
}

func (h *Handler) RenderDashboard(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, adminHTML)
}

func (h *Handler) APIStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	var totalUsers, totalKeys int
	h.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&totalUsers)
	h.db.QueryRow("SELECT COUNT(*) FROM pre_keys").Scan(&totalKeys)
	wsStats := h.hubStats()
	wsStats["total_users"] = totalUsers
	wsStats["total_prekeys"] = totalKeys
	wsStats["server_uptime"] = time.Since(h.startTime).Round(time.Second).String()
	json.NewEncoder(w).Encode(wsStats)
}

func (h *Handler) APIUsers(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	rows, err := h.db.Query(`SELECT id, phone_hash, display_name, identity_public_key, created_at, last_seen FROM users ORDER BY created_at DESC LIMIT 100`)
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	type User struct {
		ID          string     `json:"id"`
		PhoneHash   string     `json:"phone_hash"`
		DisplayName string     `json:"display_name"`
		PublicKey   string     `json:"identity_public_key"`
		CreatedAt   *time.Time `json:"created_at"`
		LastSeen    *time.Time `json:"last_seen"`
	}
	var users []User
	for rows.Next() {
		var u User
		rows.Scan(&u.ID, &u.PhoneHash, &u.DisplayName, &u.PublicKey, &u.CreatedAt, &u.LastSeen)
		users = append(users, u)
	}
	if users == nil {
		users = []User{}
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"users": users, "count": len(users)})
}

const adminHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MyPhone Admin</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1923;color:#e0e6ed;display:flex;min-height:100vh}
nav{width:220px;background:#1a2836;padding:20px 0;flex-shrink:0}
nav h2{padding:0 20px 24px;font-size:18px;color:#1a73e8}
nav a{display:block;padding:12px 20px;color:#8899a6;text-decoration:none;font-size:14px;transition:.2s}
nav a:hover,nav a.active{color:#e0e6ed;background:rgba(26,115,232,.15);border-left:3px solid #1a73e8}
main{flex:1;padding:32px}
h1{font-size:24px;margin-bottom:24px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:20px;margin-bottom:32px}
.card{background:#1a2836;border-radius:12px;padding:24px}
.card .label{font-size:13px;color:#8899a6;margin-bottom:8px;text-transform:uppercase;letter-spacing:.5px}
.card .value{font-size:32px;font-weight:700;color:#1a73e8}
.card .value.green{color:#34a853}
.card .value.yellow{color:#fbbc04}
table{width:100%;border-collapse:collapse;background:#1a2836;border-radius:12px;overflow:hidden}
th{text-align:left;padding:14px 16px;font-size:12px;color:#8899a6;text-transform:uppercase;border-bottom:1px solid #253545}
td{padding:12px 16px;font-size:13px;border-bottom:1px solid #253545}
tr:last-child td{border-bottom:none}
tr:hover{background:rgba(26,115,232,.08)}
.badge{display:inline-block;padding:2px 10px;border-radius:10px;font-size:11px;font-weight:600}
.badge.online{background:rgba(52,168,83,.2);color:#34a853}
pre{background:#0a1118;padding:16px;border-radius:8px;font-size:13px;overflow-x:auto;max-height:400px}
.refresh{color:#8899a6;font-size:12px;float:right}
.tab{display:none}.tab.active{display:block}
</style>
</head>
<body>
<nav>
<h2>🔒 MyPhone</h2>
<a href="#dashboard" class="active" onclick="switchTab('dashboard')">📊 仪表盘</a>
<a href="#users" onclick="switchTab('users')">👥 用户管理</a>
<a href="#online" onclick="switchTab('online')">🟢 在线连接</a>
<a href="#api" onclick="switchTab('api')">🔧 API 状态</a>
</nav>
<main>
<div id="tab-dashboard" class="tab active">
<h1>仪表盘 <span class="refresh" id="refresh-dashboard"></span></h1>
<div class="cards" id="cards"></div>
</div>
<div id="tab-users" class="tab">
<h1>用户管理 <span class="refresh" id="refresh-users"></span></h1>
<table><thead><tr><th>用户 ID</th><th>手机号哈希</th><th>注册时间</th><th>最后在线</th></tr></thead><tbody id="user-table"></tbody></table>
</div>
<div id="tab-online" class="tab">
<h1>在线连接 <span class="refresh" id="refresh-online"></span></h1>
<table><thead><tr><th>用户 ID</th><th>连接时间</th><th>持续时长</th></tr></thead><tbody id="online-table"></tbody></table>
</div>
<div id="tab-api" class="tab">
<h1>API 状态</h1>
<pre id="api-json">加载中...</pre>
</div>
</main>
<script>
function switchTab(name){
document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'))
document.getElementById('tab-'+name).classList.add('active')
document.querySelectorAll('nav a').forEach(a=>a.classList.remove('active'))
document.querySelector('a[href="#'+name+'"]').classList.add('active')
if(name==='api') loadAPI()
}
async function loadStats(){
const r=await fetch('/admin/api/stats')
const d=await r.json()
document.getElementById('cards').innerHTML=
'<div class="card"><div class="label">注册用户</div><div class="value">'+d.total_users+'</div></div>'+
'<div class="card"><div class="label">在线 WebSocket</div><div class="value green">'+d.online_users+'</div></div>'+
'<div class="card"><div class="label">活跃通话</div><div class="value yellow">'+d.calls_active+'</div></div>'+
'<div class="card"><div class="label">已完成通话</div><div class="value">'+d.calls_completed+'</div></div>'+
'<div class="card"><div class="label">信令消息数</div><div class="value">'+d.total_messages+'</div></div>'+
'<div class="card"><div class="label">PreKey 存量</div><div class="value">'+d.total_prekeys+'</div></div>'+
'<div class="card"><div class="label">WS 运行时间</div><div class="value" style="font-size:20px">'+d.uptime+'</div></div>'+
'<div class="card"><div class="label">服务运行时间</div><div class="value" style="font-size:20px">'+d.server_uptime+'</div></div>'
document.getElementById('refresh-dashboard').textContent='刷新: '+new Date().toLocaleTimeString()
showOnline(d)
}
function showOnline(d){
if(!d.users)return
let rows=''
d.users.forEach(u=>{rows+='<tr><td style="font-family:monospace;font-size:11px">'+u.user_id+'</td><td>'+u.connected+'</td><td><span class="badge online">'+u.uptime+'</span></td></tr>'})
document.getElementById('online-table').innerHTML=rows||'<tr><td colspan="3" style="text-align:center;color:#8899a6">暂无在线连接</td></tr>'
document.getElementById('refresh-online').textContent='刷新: '+new Date().toLocaleTimeString()
}
async function loadUsers(){
const r=await fetch('/admin/api/users')
const d=await r.json()
let rows=''
d.users.forEach(u=>{
rows+='<tr><td style="font-family:monospace;font-size:11px">'+u.id+'</td>'+
'<td style="font-family:monospace;font-size:11px">'+u.phone_hash+'</td>'+
'<td>'+(u.created_at?new Date(u.created_at).toLocaleString():'-')+'</td>'+
'<td>'+(u.last_seen?new Date(u.last_seen).toLocaleString():'-')+'</td></tr>'})
document.getElementById('user-table').innerHTML=rows||'<tr><td colspan="4" style="text-align:center;color:#8899a6">暂无注册用户</td></tr>'
document.getElementById('refresh-users').textContent='刷新: '+new Date().toLocaleTimeString()
}
async function loadAPI(){
const r=await fetch('/admin/api/stats')
const d=await r.json()
document.getElementById('api-json').textContent=JSON.stringify(d,null,2)
}
setInterval(()=>{if(document.getElementById('tab-dashboard').classList.contains('active'))loadStats()},5000)
loadStats();loadUsers()
</script>
</body>
</html>`
