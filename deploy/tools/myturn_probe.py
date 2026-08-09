#!/usr/bin/env python3
"""Minimal STUN/TURN probe for diagnosing NAT + relay on a real device (Termux-ready).

Usage:
    python3 myturn_probe.py <host> <port> [username] [password] [--count N]

Does:
  1) STUN binding  -> your public (mapped) address behind this network
  2) TURN allocate -> does this network reach the TURN server & get a relay?

Pure stdlib (socket/struct/hashlib/hmac/os/sys) — no third-party deps, runs in Termux.

Termux 使用(无需安装任何包,Termux 自带 python3):
  1. 在手机装 Termux (F-Droid 或 Play),打开
  2. 把本文件传到手机: (用 U 盘/QQ/网盘等) 放到 ~/downloads
  3. 复制到 Termux 可访问目录: cp ~/downloads/myturn_probe.py ~/
  4. 运行:
       python3 ~/myturn_probe.py 47.253.158.230 3478 myphone <TURN密码>
     若提示无 python3: pkg install python
  5. 每台手机在 对应网络(WiFi / 移动数据) 下各跑一次,把输出记下来
  ★ 注意: 手机和服务器用同一密码, 即 deploy/.env.local 里的
    MYPHONE_TURN_CREDENTIAL

Features for flaky mobile networks:
  - retries on timeout
  - persistent UDP socket (keeps 5-tuple, avoids stale-nonce 438 loop)
  - handles 438 (stale nonce) by re-fetching nonce + retry
  - correct ERROR-CODE decode (class byte * 100 + number byte)

Exit code 0 = both STUN & TURN OK. Non-zero = something failed.
"""
import hashlib, hmac, os, socket, struct, sys, time

MAGIC = 0x2112A442
BINDING = 0x0001
ALLOCATE = 0x0003
XOR_MAPPED = 0x0020
XOR_RELAYED = 0x0016
USERNAME = 0x0006
REALM = 0x0014
NONCE = 0x0015
MESSAGE_INTEGRITY = 0x0008
FINGERPRINT = 0x8028
REQUESTED_TRANSPORT = 0x0019
ERROR_CODE = 0x0009

def attr(t, v):
    v = v + b'\x00' * ((4 - len(v) % 4) % 4)
    return struct.pack('>HH', t, len(v)) + v

def msg(mtype, txn, attrs=b''):
    length = len(attrs)
    return struct.pack('>HHI', mtype, length, MAGIC) + txn + attrs

def parse(stun):
    out = {}
    off = 20
    while off + 4 <= len(stun):
        t, ln = struct.unpack('>HH', stun[off:off+4])
        v = stun[off+4:off+4+ln]
        out[t] = v
        off += 4 + ln + ((4 - ln % 4) % 4)
    return out

def addr_from_xor(v):
    port = v[2] ^ (MAGIC >> 16)
    ip = '.'.join(str(b ^ ((MAGIC >> ((3-i)*8)) & 0xff)) for i, b in enumerate(v[4:8]))
    return ip, port

def errcode(a):
    ec = a[ERROR_CODE]
    return ec[2] * 100 + ec[3]

def with_integrity(mtype, txn, attrs, user, realm, nonce, key):
    base = (attr(USERNAME, user.encode()) + attr(REALM, realm.encode()) +
            attr(NONCE, nonce.encode()) + attrs)
    length = len(base) + 24  # coturn: Length 含 MI 不含 FINGERPRINT
    msghead = struct.pack('>HHI', mtype, length, MAGIC) + txn
    hdr = msghead + base
    pad = b'\x00' * ((4 - (len(hdr) + 4) % 4) % 4)
    mi = hmac.new(key, hdr + pad, hashlib.sha1).digest()
    return hdr + attr(MESSAGE_INTEGRITY, mi)

class Probe:
    def __init__(self, host, port, timeout=5, retries=3):
        self.host, self.port = host, port
        self.timeout, self.retries = timeout, retries
        # 关键:复用同一个 socket 保持 5-tuple 稳定。
        # coturn 开了 stale-nonce,若每次请求都新建 socket(新源端口),
        # 会被判定为新会话导致 nonce 过期(438)循环。真实客户端也是复用一个连接。
        self._sock = None

    def _socket(self):
        if self._sock is None:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(self.timeout)
            self._sock = s
        return self._sock

    def _udp(self, payload):
        s = self._socket()
        for i in range(self.retries):
            try:
                s.sendto(payload, (self.host, self.port))
                data, _ = s.recvfrom(4096)
                return parse(data)
            except socket.timeout:
                time.sleep(0.3)
        return None

    def stun(self):
        a = self._udp(msg(BINDING, os.urandom(12)))
        if not a:
            print("[STUN] FAILED: no response (UDP may be blocked to this host:port)")
            return False
        if XOR_MAPPED in a:
            ip, p = addr_from_xor(a[XOR_MAPPED])
            print(f"[STUN] OK  mapped(public) address = {ip}:{p}")
            if ip.startswith(('10.', '172.16.', '172.31.', '192.168.', '100.64.')):
                print("       ⚠ mapped address is PRIVATE — you are behind another NAT layer")
            return True
        print(f"[STUN] response without XOR-MAPPED: attrs={list(a.keys())}")
        return False

    def turn(self, user, pw):
        print(f"[TURN] testing allocate on {self.host}:{self.port} ...")
        a = self._udp(msg(ALLOCATE, os.urandom(12),
                          attr(REQUESTED_TRANSPORT, b'\x11\x00\x00\x00')))
        if not a:
            print("[TURN] FAILED: no response (UDP 3478 unreachable from this network)")
            return False
        if ERROR_CODE not in a:
            print(f"[TURN] unexpected first response: attrs={list(a.keys())}")
            return False
        realm = a[REALM].decode() if REALM in a else '?'
        nonce = a[NONCE].decode() if NONCE in a else '?'
        key = hashlib.md5(f"{user}:{realm}:{pw}".encode()).digest()
        for attempt in range(self.retries + 2):
            a2 = self._udp(with_integrity(
                ALLOCATE, os.urandom(12),
                attr(REQUESTED_TRANSPORT, b'\x11\x00\x00\x00'),
                user, realm, nonce, key))
            if not a2:
                print("[TURN] FAILED: auth'd allocate timed out")
                return False
            if ERROR_CODE in a2:
                code = errcode(a2)
                if code == 401:
                    realm = a2[REALM].decode() if REALM in a2 else realm
                    nonce = a2[NONCE].decode() if NONCE in a2 else nonce
                    key = hashlib.md5(f"{user}:{realm}:{pw}".encode()).digest()
                    continue
                if code == 438:
                    nonce = a2[NONCE].decode() if NONCE in a2 else nonce
                    continue
                print(f"[TURN] allocate error {code} (auth failed? wrong user/password?)")
                return False
            if XOR_RELAYED in a2:
                rip, rp = addr_from_xor(a2[XOR_RELAYED])
                print(f"[TURN] ALLOCATE OK  relayed address = {rip}:{rp}")
                if rip.startswith(('10.', '172.16.', '172.17.', '172.18.', '172.19.',
                                   '192.168.', '100.64.')):
                    print(f"       ⚠ WARNING: relayed address is PRIVATE ({rip}) — "
                          f"remote peers cannot reach it! external-ip misconfigured?")
                else:
                    print(f"       relayed address is public — reachable ✓")
                return True
            print(f"[TURN] response attrs={list(a2.keys())}")
            return False
        print("[TURN] FAILED: too many auth retries")
        return False

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    host, port = sys.argv[1], int(sys.argv[2])
    user = sys.argv[3] if len(sys.argv) > 3 else None
    pw = sys.argv[4] if len(sys.argv) > 4 else None

    ok = True
    ok &= Probe(host, port).stun()
    if user:
        ok &= Probe(host, port).turn(user, pw)
    else:
        print("[TURN] (no credentials — skipped allocate test)")
    print("\nRESULT:", "PASS ✓" if ok else "FAIL ✗")
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
