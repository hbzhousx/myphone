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

// Middleware 是 AuthMiddleware 的 DB 增强版：JWT 校验通过后，再校验该用户
// 仍存在于 users 表且 status='active'。用于"删除用户后旧 token 立即失效"：
// 被删用户（或已禁用用户）即便持有未过期 token，也会在此被 401 拒绝。
func (h *AuthHandler) Middleware(next http.HandlerFunc) http.HandlerFunc {
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
		userID, _ := token.Claims.(jwt.MapClaims)["sub"].(string)
		if userID == "" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		// ★删号/token 即时失效：用户必须存在且处于启用状态。
		//   被删用户或已禁用用户 → 直接 401（即使 JWT 未过期）。
		var status string
		err = h.db.QueryRow(`SELECT status FROM users WHERE id=$1`, userID).Scan(&status)
		if err != nil || status != "active" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		ctx := context.WithValue(r.Context(), "userID", userID)
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

// Register 已停用：安全加固后禁止自助注册。
// 所有用户必须由管理员通过管理后台(/admin → 添加用户)录入，然后凭手机号+密码登录。
// 保留此端点仅用于给旧版客户端返回明确错误，不再创建任何用户。
func (h *AuthHandler) Register(w http.ResponseWriter, r *http.Request) {
	http.Error(w, `{"error":"self-registration disabled; users are provisioned by an administrator"}`, http.StatusForbidden)
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
