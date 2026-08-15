package main

import (
	"log"
	"net/http"
	"os"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
	_ "github.com/lib/pq"

	"github.com/myphone/server/internal/admin"
	"github.com/myphone/server/internal/api"
	"github.com/myphone/server/internal/discovery"
	"github.com/myphone/server/internal/models"
	"github.com/myphone/server/internal/ota"
	"github.com/myphone/server/internal/signaling"
)

func main() {
	dbConnStr := os.Getenv("DATABASE_URL")
	if dbConnStr == "" {
		dbConnStr = "postgres://myphone:myphone@localhost:5432/myphone?sslmode=disable"
	}
	db, err := models.NewDB(dbConnStr)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer db.Close()
	if err := db.Migrate(); err != nil {
		log.Fatalf("failed to run migrations: %v", err)
	}

	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "localhost:6379"
	}
	redisClient := models.NewRedisClient(redisAddr)

	hub := signaling.NewHub(redisClient)
	go hub.Run()

	authHandler := api.NewAuthHandler(db, redisClient)
	keysHandler := api.NewKeysHandler(db)
	contactDiscovery := discovery.NewContactDiscovery(db)
	adminHandler := admin.NewHandler(db, hub.Stats)
	otaHandler := ota.NewHandler(os.Getenv("MYPHONE_UPDATE_DIR"))
	attachmentsHandler := api.NewAttachmentsHandler(os.Getenv("MYPHONE_ATTACHMENT_DIR"))

	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(middleware.RequestID)
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{"*"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type"},
		AllowCredentials: true,
	}))

	r.Route("/v1", func(r chi.Router) {
		r.Post("/auth/register", authHandler.Register)
		r.Post("/auth/login", authHandler.Login)
		r.Post("/keys/prekeys", api.AuthMiddleware(keysHandler.UploadPreKeys))
		r.Get("/keys/prekeys/{userID}", api.AuthMiddleware(keysHandler.GetPreKeys))
		r.Get("/keys/bundle/{userID}", api.AuthMiddleware(keysHandler.GetKeyBundle))
		r.Post("/keys/signed-prekey", api.AuthMiddleware(keysHandler.UploadSignedPreKey))
		r.Put("/keys/identity", api.AuthMiddleware(keysHandler.UpdateIdentity))
		r.Get("/users/by-phone/{phoneHash}", api.AuthMiddleware(authHandler.LookupByPhoneHash))
		r.Get("/users/{userID}", api.AuthMiddleware(authHandler.LookupByUserId))
		r.Post("/users/presence", api.AuthMiddleware(func(w http.ResponseWriter, r *http.Request) {
			signaling.HandlePresence(hub, w, r)
		}))
		r.Post("/contacts/discover", api.AuthMiddleware(contactDiscovery.Discover))
		r.Post("/attachments", api.AuthMiddleware(attachmentsHandler.Upload))
		r.Get("/attachments/{id}", api.AuthMiddleware(attachmentsHandler.Download))
	})

	r.Get("/ws", api.AuthMiddleware(func(w http.ResponseWriter, r *http.Request) {
		signaling.HandleWebSocket(hub, w, r)
	}))

	r.Route("/v1/ota", otaHandler.RegisterRoutes)

	adminHandler.RegisterRoutes(r)

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("MyPhone signaling server starting on :%s", port)
	if err := http.ListenAndServe(":"+port, r); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
