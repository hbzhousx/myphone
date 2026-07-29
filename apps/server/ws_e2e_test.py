#!/usr/bin/env python3
"""WebSocket signaling E2E — Alice/Bob complete call relay test."""

import asyncio, json, sys, os, time, subprocess

BASE = "http://localhost:8080"; REST = f"{BASE}/v1"; WS = "ws://localhost:8080/ws"

g = 0; t = 0
def ok(s, c): global g,t; t+=1; g+=1 if c else 0; print(f"  {'PASS' if c else 'FAIL'} {s}"); return c

def reg(name, phone):
    r = subprocess.run(["curl","-s","-X","POST",f"{REST}/auth/register",
        "-H","Content-Type: application/json",
        "-d",json.dumps({"phone_number":phone,"password":"test","identity_public_key":f"{name}_pk"})],
        capture_output=True, text=True)
    d = json.loads(r.stdout)
    return d.get("token"), d.get("user_id")

async def main():
    global g,t
    print("\n=== MyPhone WebSocket Signaling Test ===\n")

    # 1. Build + start
    print(">>> Building & starting server...")
    subprocess.run(["pkill","-f","myphone-server"], capture_output=True)
    time.sleep(0.5)

    env = os.environ.copy()
    env.update(GOROOT=os.path.expanduser("~/go"), GOPATH=os.path.expanduser("~/go-path"),
               PATH=f"{os.path.expanduser('~/go/bin')}:{os.environ.get('PATH','')}",
               DATABASE_URL="postgres://myphone:myphone@localhost:5432/myphone?sslmode=disable",
               REDIS_ADDR="localhost:6379")
    subprocess.run(["go","build","-o","/tmp/myphone-server","./cmd/main.go"],
                   cwd=os.path.dirname(__file__), env=env, check=True)
    proc = subprocess.Popen(["/tmp/myphone-server"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    r = subprocess.run(["curl","-s",f"{BASE}/health"], capture_output=True, text=True)
    ok("Server health", r.stdout.strip() == "ok")

    # 2. Register Alice + Bob
    print("\n>>> Registering users...")
    import websockets
    now = int(time.time())
    atok, aid = reg("Alice", f"+8610000{now}")
    btok, bid = reg("Bob", f"+8610001{now}")
    if not (atok and btok): print("REGISTRATION FAILED"); proc.terminate(); sys.exit(1)
    ok("Alice registered", True); ok("Bob registered", True)
    print(f"  Alice={aid}  Bob={bid}")

    # 3. Connect WebSocket
    print("\n>>> WebSocket connections...")
    hdr_a = {"Authorization": f"Bearer {atok}"}
    hdr_b = {"Authorization": f"Bearer {btok}"}
    aws = await websockets.connect(WS, extra_headers=hdr_a)
    bws = await websockets.connect(WS, extra_headers=hdr_b)
    await asyncio.sleep(0.5)
    ok("Alice WS open", aws.open); ok("Bob WS open", bws.open)

    # 4. Offer
    print("\n>>> Offer (Alice → Bob)")
    await aws.send(json.dumps({"type":"offer","call_id":"c1","from_user_id":aid,"to_user_id":bid,"payload":{"sdp":"v=0\\r\\no=alice ..."}}))
    try:
        rx = json.loads(await asyncio.wait_for(bws.recv(), timeout=5))
        ok("Bob received offer type", rx.get("type")=="offer")
        ok("Bob received call_id", rx.get("call_id")=="c1")
        ok("Bob received SDP", "sdp" in rx.get("payload",{}))
    except asyncio.TimeoutError: ok("Bob received offer", False)

    # 5. Answer
    print("\n>>> Answer (Bob → Alice)")
    await bws.send(json.dumps({"type":"answer","call_id":"c1","from_user_id":bid,"to_user_id":aid,"payload":{"sdp":"v=0\\r\\no=bob ..."}}))
    try:
        rx = json.loads(await asyncio.wait_for(aws.recv(), timeout=5))
        ok("Alice received answer type", rx.get("type")=="answer")
        ok("Alice received call_id", rx.get("call_id")=="c1")
    except asyncio.TimeoutError: ok("Alice received answer", False)

    # 6. ICE exchange
    print("\n>>> ICE candidates (Alice → Bob → Alice)")
    await aws.send(json.dumps({"type":"iceCandidate","call_id":"c1","from_user_id":aid,"to_user_id":bid,
        "payload":{"candidate":"candidate:1 udp 10.0.0.1 12345 typ host","sdp_mid":"0","sdp_m_line_index":0}}))
    try:
        rx = json.loads(await asyncio.wait_for(bws.recv(), timeout=5))
        ok("Bob received ICE", rx.get("type")=="iceCandidate")
    except asyncio.TimeoutError: ok("Bob received ICE", False)

    await bws.send(json.dumps({"type":"iceCandidate","call_id":"c1","from_user_id":bid,"to_user_id":aid,
        "payload":{"candidate":"candidate:1 udp 192.168.1.1 54321 typ srflx","sdp_mid":"0","sdp_m_line_index":0}}))
    try:
        rx = json.loads(await asyncio.wait_for(aws.recv(), timeout=5))
        ok("Alice received ICE", rx.get("type")=="iceCandidate")
    except asyncio.TimeoutError: ok("Alice received ICE", False)

    # 7. Hangup
    print("\n>>> Hangup (Alice → Bob)")
    await aws.send(json.dumps({"type":"hangup","call_id":"c1","from_user_id":aid,"to_user_id":bid}))
    try:
        rx = json.loads(await asyncio.wait_for(bws.recv(), timeout=5))
        ok("Bob received hangup", rx.get("type")=="hangup")
    except asyncio.TimeoutError: ok("Bob received hangup", False)

    # 8. Negative: non-existent user
    print("\n>>> Negative test (ghost user)")
    await aws.send(json.dumps({"type":"offer","call_id":"ghost","from_user_id":aid,"to_user_id":"nonexistent_999"}))
    try:
        await asyncio.wait_for(bws.recv(), timeout=2)
        ok("Ghost NOT delivered to Bob", False)
    except asyncio.TimeoutError: ok("Ghost NOT delivered (correct)", True)

    await aws.close(); await bws.close()
    proc.terminate(); proc.wait(timeout=5)
    subprocess.run(["pkill","-f","myphone-server"], capture_output=True)

    print(f"\n{'='*55}\n {g}/{t} passed {' - ALL GREEN' if g==t else f' - {t-g} FAILURES'}\n{'='*55}\n")
    return g==t

if __name__ == "__main__":
    rc = asyncio.run(main())
    sys.exit(0 if rc else 1)
