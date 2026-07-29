# MyPhone — Encrypted Calling App

Cross-platform (Android + iOS) encrypted calling app built with Flutter and Go.

## Features

- **End-to-End Encrypted Calls** — Signal Protocol (X3DH + Double Ratchet) + DTLS-SRTP
- **Low-Bandwidth Resilience** — Opus SILK adaptive codec (6–40 kbps) with FEC, PLC, DTX
- **Contact Discovery** — Privacy-preserving phone number hashing (SHA-256 + salt)
- **Biometric Login** — Fingerprint/Face ID via BiometricPrompt (Android) / LAContext (iOS)

## Architecture

```
apps/mobile/    — Flutter app (Android + iOS)
apps/server/    — Go signaling server (WebSocket + REST API)
```

### Client
- **Framework**: Flutter 3.x + Riverpod
- **Call Engine**: WebRTC + Opus SILK + DTLS-SRTP
- **Crypto**: libsignal (Signal Protocol FFI)
- **Storage**: SQLCipher (encrypted SQLite)
- **Auth**: BiometricPrompt / LAContext + FlutterSecureStorage

### Server
- **Language**: Go + Chi router
- **Signaling**: WebSocket hub (Gorilla WebSocket)
- **Database**: PostgreSQL
- **Cache**: Redis (sessions, pre-key cache)

## Project Structure

```
apps/mobile/lib/
├── main.dart
├── app/            # Router, theme, auth guard
├── features/
│   ├── auth/       # Biometric login, registration
│   ├── calls/      # Call engine, dialer, call UI
│   └── contacts/   # Contact discovery, sync, UI
├── core/
│   ├── crypto/     # Signal Protocol wrapper
│   ├── webrtc/     # WebRTC + Opus + network monitor
│   ├── network/    # HTTP API + WebSocket signaling
│   └── storage/    # SQLCipher database
└── shared/models/  # User, Contact, CallHistory

apps/server/
├── cmd/main.go
└── internal/
    ├── api/        # Auth, keys handlers
    ├── signaling/  # WebSocket hub
    ├── discovery/  # Contact discovery
    └── models/     # DB + Redis clients
```

## Getting Started

### Prerequisites
- Flutter SDK 3.2+, Go 1.22+, PostgreSQL 15+, Redis 7+

### Mobile App
```bash
cd apps/mobile && flutter pub get && flutter run
```

### Signaling Server
```bash
cd apps/server && go mod tidy
DATABASE_URL="postgres://..." go run cmd/main.go
```

## Opus Codec Tiers

| Tier | RTT | Loss | Bitrate | FEC | DTX |
|------|-----|------|---------|-----|-----|
| Good | < 100ms | < 2% | 32 kbps | Off | Off |
| Moderate | 100-500ms | 2-10% | 12 kbps | On | On |
| Poor | > 500ms | 10-30% | 6 kbps | Max | On |

## Security

- All calls: DTLS-SRTP (AES-128-GCM)
- Signaling: server only relays encrypted SDP
- Contacts: SHA-256 hashed locally before upload
- At rest: SQLCipher AES-256-GCM
- Auth tokens: Android Keystore / iOS Keychain

## License

MIT
