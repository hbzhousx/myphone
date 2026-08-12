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
