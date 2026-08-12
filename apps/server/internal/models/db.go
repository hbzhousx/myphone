package models

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/lib/pq"
	"github.com/redis/go-redis/v9"
)

type DB struct{ *sql.DB }
type Client = redis.Client

func NewDB(connStr string) (*DB, error) {
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("db.Ping: %w", err)
	}
	return &DB{db}, nil
}

func (db *DB) Migrate() error {
	migrations := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id TEXT PRIMARY KEY, phone_hash TEXT UNIQUE NOT NULL,
			display_name TEXT NOT NULL DEFAULT '',
			identity_public_key TEXT NOT NULL, password_hash TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW())`,
		`CREATE INDEX IF NOT EXISTS idx_users_phone_hash ON users(phone_hash)`,
		`CREATE TABLE IF NOT EXISTS pre_keys (
			id SERIAL PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
			key_id INTEGER NOT NULL, public_key TEXT NOT NULL,
			is_used BOOLEAN NOT NULL DEFAULT FALSE, UNIQUE(user_id, key_id))`,
		`CREATE TABLE IF NOT EXISTS signed_pre_keys (
			user_id TEXT PRIMARY KEY REFERENCES users(id),
			key_id INTEGER NOT NULL, public_key TEXT NOT NULL,
			signature TEXT NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`,
		`CREATE INDEX IF NOT EXISTS idx_pre_keys_used ON pre_keys(user_id, is_used)`,
		`ALTER TABLE users ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active'`,
		`CREATE TABLE IF NOT EXISTS cdr (
			id SERIAL PRIMARY KEY,
			call_id TEXT NOT NULL,
			caller_id TEXT NOT NULL,
			callee_id TEXT NOT NULL,
			direction TEXT NOT NULL DEFAULT 'outgoing',
			status TEXT NOT NULL DEFAULT 'unknown',
			started_at TIMESTAMPTZ NOT NULL,
			ended_at TIMESTAMPTZ,
			duration_secs INTEGER DEFAULT 0,
			codec TEXT DEFAULT 'opus',
			avg_bitrate_kbps INTEGER DEFAULT 0,
			packet_loss_pct REAL DEFAULT 0,
			rtt_ms REAL DEFAULT 0,
			caller_ip TEXT DEFAULT '',
			callee_ip TEXT DEFAULT '')`,
		`CREATE INDEX IF NOT EXISTS idx_cdr_started ON cdr(started_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_cdr_caller ON cdr(caller_id)`,
		`CREATE TABLE IF NOT EXISTS admin_logs (
			id SERIAL PRIMARY KEY,
			action TEXT NOT NULL,
			detail TEXT DEFAULT '',
			operator TEXT DEFAULT 'system',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`,
	}
	for _, m := range migrations {
		if _, err := db.Exec(m); err != nil {
			return fmt.Errorf("migration: %w", err)
		}
	}
	return nil
}

func NewRedisClient(addr string) *redis.Client {
	return redis.NewClient(&redis.Options{Addr: addr, Password: "", DB: 0})
}
