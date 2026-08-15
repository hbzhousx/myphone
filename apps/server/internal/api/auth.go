package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/myphone/server/internal/models"
	"golang.org/x/crypto/bcrypt"
)

var jwtSecret = []byte("myphone-jwt-secret-change-in-production")

func AuthMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if auth == "" || !strings.HasPrefix(auth, "Bearer ") {
			// Fallback: WebSocket connections pass token as query parameter.
			if q := r.URL.Query().Get("token"); q != "" {
				auth = "Bearer " + q
			}
		}
		if auth == "" || !strings.HasPrefix(auth, "Bearer ") {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		tokenStr := strings.TrimPrefix(auth, "Bearer ")
		token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) { return jwtSecret, nil })
		if err != nil || !token.Valid {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		ctx := context.WithValue(r.Context(), "userID", token.Claims.(jwt.MapClaims)["sub"])
		next(w, r.WithContext(ctx))
	}
}

type AuthHandler struct {
	db    *models.DB
	redis *models.Client
}

func NewAuthHandler(db *models.DB, redis *models.Client) *AuthHandler {
	return &AuthHandler{db: db, redis: redis}
}

type RegisterRequest struct {
	PhoneNumber       string `json:"phone_number"`
	Password          string `json:"password"`
	IdentityPublicKey string `json:"identity_public_key"`
	DisplayName       string `json:"display_name"`
}

func (h *AuthHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	if req.PhoneNumber == "" || req.Password == "" || req.IdentityPublicKey == "" {
		http.Error(w, `{"error":"missing required fields"}`, http.StatusBadRequest)
		return
	}
	passwordHash, _ := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	userID := generateID()
	// Store the plaintext phone number as the display name so callers/callees
	// can show a readable number instead of a phone-hash or UUID.
	displayName := req.DisplayName
	if displayName == "" {
		displayName = req.PhoneNumber
	}
	// ★修复：已存在的手机号（重装/清数据后重新注册）必须更新 identity_public_key。
	//   否则本地重新生成的新 identity 与服务器旧值不一致 → 对端取 bundle 拿到旧
	//   IK，本机用新 IK → X3DH DH1/DH2 不对称 → 每条消息解密 MAC 失败。
	//   用 ON CONFLICT 在 phone_hash 唯一冲突时更新 identity（保留原 user_id/密码）。
	_, err := h.db.Exec(
		`INSERT INTO users (id, phone_hash, identity_public_key, password_hash, display_name) VALUES ($1,$2,$3,$4,$5)
		 ON CONFLICT (phone_hash) DO UPDATE SET identity_public_key = EXCLUDED.identity_public_key`,
		userID, hashPhone(req.PhoneNumber), req.IdentityPublicKey, string(passwordHash), displayName,
	)
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	// 已存在用户（ON CONFLICT 更新）时，取数据库里的原 user_id，保持身份稳定
	// （对端缓存的 user_id 不变，否则消息路由会断）。
	var actualID string
	if err := h.db.QueryRow(
		`SELECT id FROM users WHERE phone_hash = $1`, hashPhone(req.PhoneNumber),
	).Scan(&actualID); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	token := generateJWT(actualID)
	json.NewEncoder(w).Encode(map[string]interface{}{"token": token, "user_id": actualID})
}

type LoginRequest struct {
	PhoneNumber string `json:"phone_number"`
	Password    string `json:"password"`
}

func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	json.NewDecoder(r.Body).Decode(&req)
	log.Printf("[AUTH] Login phone=%q hash=%s", req.PhoneNumber, hashPhone(req.PhoneNumber))
	phoneHash := hashPhone(req.PhoneNumber)
	var userID, passwordHash string
	err := h.db.QueryRow(`SELECT id, password_hash FROM users WHERE phone_hash = $1`, phoneHash).Scan(&userID, &passwordHash)
	if err != nil || bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(req.Password)) != nil {
		http.Error(w, `{"error":"invalid credentials"}`, http.StatusUnauthorized)
		return
	}
	token := generateJWT(userID)
	json.NewEncoder(w).Encode(map[string]interface{}{"token": token, "user_id": userID})
}

func generateJWT(userID string) string {
	claims := jwt.MapClaims{"sub": userID, "iat": time.Now().Unix(), "exp": time.Now().Add(30 * 24 * time.Hour).Unix()}
	token, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(jwtSecret)
	return token
}

func (h *AuthHandler) LookupByUserId(w http.ResponseWriter, r *http.Request) {
	userID := chi.URLParam(r, "userID")
	var phoneHash, displayName string
	err := h.db.QueryRow(`SELECT phone_hash, display_name FROM users WHERE id = $1`, userID).Scan(&phoneHash, &displayName)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	json.NewEncoder(w).Encode(map[string]string{
		"user_id": userID, "phone_hash": phoneHash, "display_name": displayName,
	})
}

func (h *AuthHandler) LookupByPhoneHash(w http.ResponseWriter, r *http.Request) {
	phoneHash := chi.URLParam(r, "phoneHash")
	var userID string
	err := h.db.QueryRow(`SELECT id FROM users WHERE phone_hash = $1`, phoneHash).Scan(&userID)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"user_id": userID})
}

func hashPhone(phone string) string {
	h := sha256.Sum256([]byte("myphone-salt:" + phone))
	return hex.EncodeToString(h[:])
}

var _ = context.Background // keep import
