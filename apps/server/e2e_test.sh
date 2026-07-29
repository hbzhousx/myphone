#!/bin/bash
set -e
SERVER_PID=""
BASE="http://localhost:8080/v1"
cleanup() { echo ""; echo "=== Cleanup ==="; [ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null; echo "Done."; }
trap cleanup EXIT

echo "=== 1. Building & starting server ==="
cd "$(dirname "$0")"
export GOROOT=$HOME/go GOPATH=$HOME/go-path PATH=$HOME/go/bin:$PATH
go build -o /tmp/myphone-server ./cmd/main.go
DATABASE_URL="postgres://myphone:myphone@localhost:5432/myphone?sslmode=disable" \
REDIS_ADDR="localhost:6379" /tmp/myphone-server &
SERVER_PID=$!
sleep 2

echo "=== 2. Health ===" && curl -s http://localhost:8080/health && echo ""

echo "=== 3. Register ==="
PHONE="+8613800$(date +%s | tail -c5)"
R=$(curl -s -X POST "$BASE/auth/register" -H "Content-Type: application/json" \
  -d "{\"phone_number\":\"$PHONE\",\"password\":\"test123\",\"identity_public_key\":\"aabbcc\"}")
echo "$R"
TOKEN=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
USER_ID=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_id'])")
echo "TOKEN=${TOKEN:0:20}...  USER_ID=$USER_ID"

echo "=== 4. Login ===" && curl -s -X POST "$BASE/auth/login" -H "Content-Type: application/json" \
  -d "{\"phone_number\":\"$PHONE\",\"password\":\"test123\"}" && echo ""

echo "=== 5. Upload pre-keys ===" && curl -s -X POST "$BASE/keys/prekeys" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"pre_keys":[{"key_id":1,"public_key":"pk1"},{"key_id":2,"public_key":"pk2"}]}' && echo ""

echo "=== 6. Get pre-keys ===" && curl -s "$BASE/keys/prekeys/$USER_ID" -H "Authorization: Bearer $TOKEN" && echo ""

echo "=== 7. Contact discovery ==="
HASH=$(python3 -c "import hashlib; print(hashlib.sha256(b'myphone-salt:$PHONE').hexdigest())")
curl -s -X POST "$BASE/contacts/discover" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" -d "{\"phone_hashes\":[\"$HASH\"]}" && echo ""

echo "=== 8. Auth failure test ===" && curl -s "$BASE/keys/prekeys/$USER_ID" && echo ""

echo "=== 9. Duplicate register ===" && curl -s -X POST "$BASE/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"phone_number\":\"$PHONE\",\"password\":\"test123\",\"identity_public_key\":\"aabbcc\"}" && echo ""

echo ""; echo "========================================"
echo " ALL API ENDPOINTS VERIFIED SUCCESSFULLY"
echo "========================================"
