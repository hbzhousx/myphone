package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
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

func generateID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
