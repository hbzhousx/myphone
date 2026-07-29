package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/myphone/server/internal/models"
	"golang.org/x/crypto/bcrypt"
)

var jwtSecret = []byte("myphone-jwt-secret-change-in-production")

func AuthMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
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
	_, err := h.db.Exec(
		`INSERT INTO users (id, phone_hash, identity_public_key, password_hash) VALUES ($1,$2,$3,$4)`,
		userID, hashPhone(req.PhoneNumber), req.IdentityPublicKey, string(passwordHash),
	)
	if err != nil {
		http.Error(w, `{"error":"user already exists"}`, http.StatusConflict)
		return
	}
	token := generateJWT(userID)
	json.NewEncoder(w).Encode(map[string]interface{}{"token": token, "user_id": userID})
}

type LoginRequest struct {
	PhoneNumber string `json:"phone_number"`
	Password    string `json:"password"`
}

func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	json.NewDecoder(r.Body).Decode(&req)
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

func hashPhone(phone string) string {
	h := sha256.Sum256([]byte("myphone-salt:" + phone))
	return hex.EncodeToString(h[:])
}

var _ = context.Background // keep import
