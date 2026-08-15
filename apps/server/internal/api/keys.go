package api

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/myphone/server/internal/models"
)

type KeysHandler struct{ db *models.DB }

func NewKeysHandler(db *models.DB) *KeysHandler { return &KeysHandler{db: db} }

type PreKeyRequest struct {
	PreKeys []PreKey `json:"pre_keys"`
}

type PreKey struct {
	KeyID     int    `json:"key_id"`
	PublicKey string `json:"public_key"`
}

func (h *KeysHandler) UploadPreKeys(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("userID").(string)
	var req PreKeyRequest
	json.NewDecoder(r.Body).Decode(&req)
	// ★关键修复：上传新批次前先清掉该用户的旧 OTP，避免孤儿 OTP 残留。
	// 旧批次（尤其 key_id 与当前批次不同的孤儿）留在服务器会被 GetKeyBundle 按
	// key_id 取到，但客户端本地已无对应私钥 → 发起方用孤儿公钥做 DH4、响应方
	// 缺私钥 → 两端 X3DH 失配 → 消息解密失败(MAC) / 灰块。
	// 清旧再插保证服务器永远只有当前批次，GetKeyBundle 取到的必是响应方有私钥的。
	if _, err := h.db.Exec(`DELETE FROM pre_keys WHERE user_id = $1`, userID); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	for _, pk := range req.PreKeys {
		h.db.Exec(`INSERT INTO pre_keys (user_id, key_id, public_key) VALUES ($1,$2,$3)`, userID, pk.KeyID, pk.PublicKey)
	}
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (h *KeysHandler) GetPreKeys(w http.ResponseWriter, r *http.Request) {
	targetUserID := chi.URLParam(r, "userID")
	rows, err := h.db.Query(`SELECT key_id, public_key FROM pre_keys WHERE user_id = $1 AND is_used = FALSE LIMIT 1`, targetUserID)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	defer rows.Close()
	var preKeys []PreKey
	for rows.Next() {
		var pk PreKey
		rows.Scan(&pk.KeyID, &pk.PublicKey)
		preKeys = append(preKeys, pk)
	}
	if len(preKeys) == 0 {
		http.Error(w, `{"error":"no pre-keys available"}`, http.StatusNotFound)
		return
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"pre_keys": preKeys})
}

// UpdateIdentityRequest 携带新的 identity_public_key。
type UpdateIdentityRequest struct {
	IdentityPublicKey string `json:"identity_public_key"`
}

// UpdateIdentity 更新当前用户的 identity_public_key。
// ★关键：登录/启动后同步本地 identity 到服务器，避免重装/清数据后本地新 identity
//   与服务器旧值不一致 → 对端取 bundle 拿旧 IK，本机用新 IK → X3DH DH2 不对称
//   → 每条消息解密 MAC 失败。
func (h *KeysHandler) UpdateIdentity(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("userID").(string)
	var req UpdateIdentityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.IdentityPublicKey == "" {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	if _, err := h.db.Exec(
		`UPDATE users SET identity_public_key = $1 WHERE id = $2`,
		req.IdentityPublicKey, userID,
	); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

type SignedPreKeyRequest struct {
	KeyID     int    `json:"key_id"`
	PublicKey string `json:"public_key"`
	Signature string `json:"signature"`
}

func (h *KeysHandler) UploadSignedPreKey(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("userID").(string)
	var req SignedPreKeyRequest
	json.NewDecoder(r.Body).Decode(&req)
	h.db.Exec(
		`INSERT INTO signed_pre_keys (user_id, key_id, public_key, signature, updated_at)
		 VALUES ($1,$2,$3,$4,NOW()) ON CONFLICT (user_id) DO UPDATE
		 SET key_id=$2, public_key=$3, signature=$4, updated_at=NOW()`,
		userID, req.KeyID, req.PublicKey, req.Signature,
	)
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// KeyBundleHandler 返回目标用户的完整 prekey 束（identity + signed-prekey + 一个
// 一次性 prekey），供聊天 X3DH 发起方使用。一次性 prekey 在事务中原子标记 used，
// 避免两个发起方拿到同一个 prekey。
func (h *KeysHandler) GetKeyBundle(w http.ResponseWriter, r *http.Request) {
	targetUserID := chi.URLParam(r, "userID")
	if targetUserID == "" {
		http.Error(w, `{"error":"missing userID"}`, http.StatusBadRequest)
		return
	}

	// 1) identity public key
	var identityPub string
	if err := h.db.QueryRow(
		`SELECT identity_public_key FROM users WHERE id = $1`, targetUserID,
	).Scan(&identityPub); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		} else {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		}
		return
	}

	// 2) signed prekey（最新）
	var spkID int
	var spkPub, spkSig string
	if err := h.db.QueryRow(
		`SELECT key_id, public_key, signature FROM signed_pre_keys
		 WHERE user_id = $1 ORDER BY updated_at DESC LIMIT 1`, targetUserID,
	).Scan(&spkID, &spkPub, &spkSig); err != nil {
		http.Error(w, `{"error":"no signed prekey"}`, http.StatusNotFound)
		return
	}

	// 3) 一次性 prekey：FOR UPDATE SKIP LOCKED 原子取用并标记 used。
	//    用尽时返回 one_time_prekey:null（客户端回退 3-DH X3DH），不报错。
	tx, err := h.db.Begin()
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	var opkID int
	var opkPub string
	var oneTime *OneTimePreKeyResp
	err = tx.QueryRow(
		`SELECT key_id, public_key FROM pre_keys
		 WHERE user_id = $1 AND is_used = FALSE ORDER BY key_id
		 LIMIT 1 FOR UPDATE SKIP LOCKED`, targetUserID,
	).Scan(&opkID, &opkPub)
	if err == nil {
		if _, err := tx.Exec(
			`UPDATE pre_keys SET is_used = TRUE WHERE user_id = $1 AND key_id = $2`,
			targetUserID, opkID,
		); err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		oneTime = &OneTimePreKeyResp{KeyID: opkID, PublicKey: opkPub}
	} else if !errors.Is(err, sql.ErrNoRows) {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"user_id":             targetUserID,
		"identity_public_key": identityPub,
		"signed_prekey": SignedPreKeyResp{
			KeyID:     spkID,
			PublicKey: spkPub,
			Signature: spkSig,
		},
		"one_time_prekey": oneTime,
	})
}

type SignedPreKeyResp struct {
	KeyID     int    `json:"key_id"`
	PublicKey string `json:"public_key"`
	Signature string `json:"signature"`
}

type OneTimePreKeyResp struct {
	KeyID     int    `json:"key_id"`
	PublicKey string `json:"public_key"`
}

func generateID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
