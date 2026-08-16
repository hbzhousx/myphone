# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

MyPhone is an end-to-end encrypted **calling + 1:1 chat app for Android**: a Flutter client and a Go signaling server in one repo. Docs, deploy scripts, and commit messages are written in Chinese (中文) — match that when writing new ones.

```
apps/mobile/   Flutter client (Android is the real target; iOS/macOS/desktop are scaffold stubs)
apps/server/   Go signaling server (chi router + gorilla WebSocket hub + PostgreSQL + Redis)
deploy/        Production deployment scripts + artifacts for the Aliyun server
docs/          Version feature designs (v0.4 resident process, v0.5 chat) — read these before touching those features
third_party/   Vendored sqflite_sqlcipher fork (SQLCipher-backed SQLite)
```

## Commands

### Mobile (`cd apps/mobile`)
- `flutter pub get` — install deps (prefer `--offline` if the network is flaky)
- `flutter run` — run against the compile-time server config (defaults to LAN IP `192.168.3.113:8080`)
- `flutter test` — all Dart tests; the crypto tests live in `test/core/crypto/` (ratchet/X3DH round-trips, out-of-order delivery, tamper rejection)
- `flutter test test/core/crypto/chat_crypto_test.dart` — a single test file
- `flutter analyze` — lint (flutter_lints)
- `flutter build apk --debug` — debug APK with default config
- `../../deploy/build-apk.sh` — production release APK; requires `deploy/.env.local` (copied from `build.env.example`)
- Device logs: `adb logcat -s flutter`

### Server (`cd apps/server`)
- Go is a custom install: `export GOROOT=$HOME/go GOPATH=$HOME/go-path PATH=$HOME/go/bin:$PATH`
- `go build -o server ./cmd/` then `./server` (listens on `:8080`)
- `go test ./...` — unit tests (signaling hub only, no DB required)
- `bash e2e_test.sh` — end-to-end API test; requires local PostgreSQL + Redis running
- Local env: `DATABASE_URL=postgres://myphone:myphone@localhost:5432/myphone?sslmode=disable`, `REDIS_ADDR=localhost:6379`

### Deploy (`cd deploy`)
- `build-server.sh` — cross-compile the Go server → `deploy/artifacts/myphone-server` (run on the dev machine)
- `install-deps.sh` / `init-db.sh` / `deploy-server.sh` / `verify.sh` / `backup.sh` / `restore.sh` — run on the Aliyun server
- Full runbook: `deploy/README.md` and `docs/deploy/阿里云部署手册.md`

## Architecture

### Compile-time config (mobile)
Server/STUN/TURN settings are baked into the APK via `--dart-define` and read in `lib/core/network/server_config.dart` (`String.fromEnvironment`). **Changing the server address requires rebuilding the APK** — there is no runtime config.

### WebSocket signaling must be a singleton
The server keeps **exactly one** WS connection per user; a new connection kicks the old one (newer connection wins). `lib/core/network/service_bridge.dart` enforces a single cached `SignalingClient` shared by both the call and chat state providers (`createSignalingClient()`). Never open a second WebSocket — it causes mutual reconnects and "callee offline" failures. This constraint is documented in that file.

### Resident process (v0.4, Android)
A native foreground service exclusively owns the WebSocket so calls still ring after the app is swiped away. In this mode Flutter does **not** open its own WS: it sends via `ServiceBridgeSignalingClient` over a `myphone/service` MethodChannel and receives via EventChannel. Toggled from Settings (`ResidentService.enabled`). The Go server was deliberately *not* changed for this.

### Crypto is self-written Dart, not libsignal
`lib/core/crypto/` implements Signal-style X3DH + Double Ratchet (X25519 + AES-256-GCM) in pure Dart:
- `crypto_manager.dart` — call E2EE
- `chat_crypto.dart` + `chat_session_manager.dart` — chat session ratchet (out-of-order skipped-key buffer, AAD session binding, session persistence)

The README mentions a libsignal FFI, but the `native/` dir is empty — the crypto is all Dart.

### Signaling protocol
WS messages are JSON envelopes `{type, from_user_id, to_user_id, payload}`. Call types: `offer / answer / iceCandidate / ringing / hangup / busy`. Chat types: `chatInit / chatMessage / chatReceipt / chatTyping / chatDisappearing / chatFileOffer / chatFileAnswer / chatFileIce / chatFileDone`. Chat file bytes travel over a WebRTC DataChannel P2P; the server relays only signaling and sees only ciphertext. New message types are dispatched in `lib/core/network/signaling_client.dart` — unknown types route to the `chatSignals` stream.

### Chat offline delivery
A `chatMessage` to an offline recipient goes into a Redis queue (`chat:queue:<userID>`, 24h TTL, dedup via `chat:seen:*`), flushed FIFO on reconnect. Handled in `apps/server/internal/signaling/hub.go`.

### Server
- `cmd/main.go` wires all routes: `/v1/auth/*`, `/v1/keys/*`, `/v1/contacts/discover`, `/v1/users/*`, `/ws`, `/v1/ota`, `/admin`, `/health`.
- DB migrations run **automatically at startup** (`models/db.go` `Migrate()`); there is no migration tooling.
- Privacy: phone numbers are stored only as `SHA256("myphone-salt:" + phone)`; user IDs are random 16-byte hex (unrelated to the number); JWTs are valid 30 days.
- Per-call metrics (`cdr` table) drive the admin dashboard (`internal/admin/admin.go`).

### State management (mobile)
Riverpod `Notifier` classes, hand-written. The `build_runner`/freezed/riverpod_generator dev deps exist but **no codegen is currently in use** — there are no `@freezed`/`@riverpod` annotations and `*.g.dart` / `*.freezed.dart` are gitignored. Keep new state classes as plain Notifiers, or if you add codegen, un-ignore the generated files or CI/other devs will break.

## Testing workflow

- Server: `go test ./...` for unit, `bash e2e_test.sh` for API flow (needs PG + Redis).
- Mobile: `flutter test` for crypto/unit; most behavior is QA'd manually on two real devices with `adb logcat -s flutter`.
- Known manual-test pitfalls and their fixes are tracked in `design.md` (section 八/十) — check it before debugging call/chat symptoms.
