#!/usr/bin/env python3
"""TURN relay-to-relay test on a single server.
Two TURN allocations from this host; A sends a payload to B's relayed address
via a SEND indication; B echoes back. Verifies same-server relay forwarding.
Usage: turn_relay_test.py <host> <port> <user> <password>

!! CAUTION (2026-08-08) !!
本脚本是早期自制诊断工具,在"双分配互发回显"场景的判定**已被证明不可靠**
(发送方等待对端回显的逻辑有缺陷,曾被误判为服务器 relay 故障)。
★ 权威的 relay-to-relay 判定请用官方工具:
    turnutils_uclient -y -m 2 -u <user> -w <pass> -p 3478 <server>
本脚本仅保留用于单分配 / 查中继通告地址等非回显场景。
"""
import hashlib, hmac, os, socket, struct, sys, time

MAGIC = 0x2112A442
BINDING=0x0001; ALLOCATE=0x0003; REFRESH=0x0004; CREATE_PERM=0x0008; SEND=0x0016; DATA_IND=0x0017
XOR_MAPPED=0x0020; XOR_RELAYED=0x0016; XOR_PEER=0x0012; DATA=0x0013
USERNAME=0x0006; REALM=0x0014; NONCE=0x0015; MI=0x0008; FP=0x8028
REQ_TRANSPORT=0x0019; ERR=0x0009; LIFETIME=0x000d

def attr(t, v):
    v += b'\x00' * ((4 - len(v) % 4) % 4)
    return struct.pack('>HH', t, len(v)) + v

def msg(mtype, txn, attrs=b''):
    return struct.pack('>HHI', mtype, len(attrs), MAGIC) + txn + attrs

def parse(b):
    out={}; off=20
    while off+4 <= len(b):
        t, ln = struct.unpack('>HH', b[off:off+4])
        out[t]=b[off+4:off+4+ln]; off += 4+ln+((4-ln%4)%4)
    return out

def xaddr(ip, port):
    xp = port ^ (MAGIC >> 16)
    xi = bytes(b ^ ((MAGIC >> ((3-i)*8)) & 0xff) for i, b in enumerate(socket.inet_aton(ip)))
    return b'\x01' + struct.pack('>H', xp) + xi + b'\x00'

def unxaddr(v):
    xp = struct.unpack('>H', v[2:4])[0] ^ (MAGIC >> 16)
    xi = bytes(b ^ ((MAGIC >> ((3-i)*8)) & 0xff) for i, b in enumerate(v[4:8]))
    return socket.inet_ntoa(xi), xp

def sig(mtype, txn, attrs, key, realm, nonce, username):
    base = attr(USERNAME, username.encode()) + attr(REALM, realm.encode()) + attr(NONCE, nonce.encode()) + attrs
    # coturn 4.15: Length 字段含 MI(24)但【不含】FINGERPRINT;不带 FP 最稳
    length = len(base) + 24
    hdr = struct.pack('>HHI', mtype, length, MAGIC) + txn + base
    pad = b'\x00' * ((4 - (len(hdr)+4) % 4) % 4)
    mi = hmac.new(key, hdr+pad, hashlib.sha1).digest()
    return hdr + attr(MI, mi)

def errcode(a):
    ec = a[ERR]
    # coturn: value = 2B reserved + class byte + number byte -> v[2]*100+v[3]
    return ec[2] * 100 + ec[3]

class Client:
    def __init__(self, host, port, user, pw, name):
        self.host=host; self.port=port; self.user=user; self.pw=pw; self.name=name
        self.sock=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # 显式绑定本地源端口,模拟不同客户端,避免两个分配共享同一 5-tuple 触发 437
        self.sock.bind(('0.0.0.0', 0))
        self.sock.settimeout(5)
        self.realm=None; self.nonce=None; self.key=None
        self.relay=None

    def mapped_addr(self, tries=3):
        """STUN binding, 返回本客户端经 NAT 后的公网源端口(用于确认两客户端端口不同)。"""
        for i in range(tries):
            txn = os.urandom(12)
            self.sock.sendto(msg(BINDING, txn), (self.host, self.port))
            a = self._recv(timeout=3)
            if a and XOR_MAPPED in a:
                return unxaddr(a[XOR_MAPPED])
            time.sleep(0.3)
        return None

    def _recv(self, timeout=5):
        self.sock.settimeout(timeout)
        try:
            d,_ = self.sock.recvfrom(4096)
            return parse(d)
        except socket.timeout:
            return None

    def alloc(self):
        txn = os.urandom(12)
        self.sock.sendto(msg(ALLOCATE, txn, attr(REQ_TRANSPORT, b'\x11\x00\x00\x00')), (self.host, self.port))
        a = self._recv()
        if not a or ERR not in a:
            print(f"[{self.name}] alloc: no challenge"); return False
        self.realm = a[REALM].decode(); self.nonce = a[NONCE].decode()
        self.key = hashlib.md5(f"{self.user}:{self.realm}:{self.pw}".encode()).digest()
        return self._alloc_authed()

    def _alloc_authed(self, tries=4):
        for i in range(tries):
            txn = os.urandom(12)
            req = sig(ALLOCATE, txn, attr(REQ_TRANSPORT, b'\x11\x00\x00\x00'), self.key, self.realm, self.nonce, self.user)
            self.sock.sendto(req, (self.host, self.port))
            a = self._recv()
            if a is None:
                time.sleep(0.5); continue
            if ERR in a:
                c = errcode(a)
                if c == 401:
                    self.realm = a[REALM].decode(); self.nonce = a[NONCE].decode()
                    self.key = hashlib.md5(f"{self.user}:{self.realm}:{self.pw}".encode()).digest()
                    continue
                if c == 438:
                    self.nonce = a[NONCE].decode(); continue
                print(f"[{self.name}] alloc error {c}"); return False
            if XOR_RELAYED in a:
                self.relay = unxaddr(a[XOR_RELAYED])
                print(f"[{self.name}] ALLOC OK relayed={self.relay[0]}:{self.relay[1]}")
                return True
        print(f"[{self.name}] alloc failed after retries"); return False

    def create_permission(self, ip, tries=4):
        txn = os.urandom(12)
        attrs = attr(XOR_PEER, xaddr(ip, 0))
        for i in range(tries):
            req = sig(CREATE_PERM, txn, attrs, self.key, self.realm, self.nonce, self.user)
            self.sock.sendto(req, (self.host, self.port))
            a = self._recv(timeout=3)
            if a is None:
                time.sleep(0.5); continue
            if ERR in a:
                c = errcode(a)
                if c == 438:
                    self.nonce = a[NONCE].decode(); continue
                print(f"[{self.name}] CreatePermission error {c}"); return False
            return True   # success response
        return False

    def send_to(self, peer_addr, payload, tries=4):
        ip, port = peer_addr
        if not self.create_permission(ip):
            print(f"[{self.name}] CreatePermission failed for {ip}"); return None
        txn = os.urandom(12)
        attrs = attr(XOR_PEER, xaddr(ip, port)) + attr(DATA, payload)
        for i in range(tries):
            req = sig(SEND, txn, attrs, self.key, self.realm, self.nonce, self.user)
            self.sock.sendto(req, (self.host, self.port))
            a = self._recv(timeout=3)
            if a is None:
                time.sleep(0.5); continue
            if ERR in a and errcode(a) == 438:
                self.nonce = a[NONCE].decode(); continue
            if DATA_IND in a:
                return a[DATA]
            if ERR in a:
                print(f"[{self.name}] send error {errcode(a)}"); return None
            a2 = self._recv(timeout=2)
            if a2 and DATA_IND in a2:
                return a2[DATA]
        return None

def main():
    host, port = sys.argv[1], int(sys.argv[2])
    user, pw = sys.argv[3], sys.argv[4]
    A = Client(host, port, user, pw, "A")
    B = Client(host, port, user, pw, "B")
    # 打印两客户端 STUN 映射地址,确认它们是"不同公网源端口"(模拟不同 NAT 后端)
    mA = A.mapped_addr(); mB = B.mapped_addr()
    print(f"[MAP] A stun-mapped={mA}  B stun-mapped={mB}")
    if mA and mB and mA[1] == mB[1]:
        print("[MAP] WARNING: 两客户端映射到同一公网源端口,将触发 437,测试无效")
    if not (A.alloc() and B.alloc()):
        print("RESULT: allocation failed"); sys.exit(1)
    print(f"--- A sends to B relay {B.relay[0]}:{B.relay[1]} via TURN ---")
    t0 = time.time()
    got = A.send_to(B.relay, b"hello-from-A")
    dt = (time.time()-t0)*1000
    if got == b"hello-from-A":
        print(f"RESULT: A->B relay forwarding OK ({dt:.0f}ms)")
    else:
        print(f"RESULT: A->B FAILED got={got!r}")
    print(f"--- B echoes back to A relay {A.relay[0]}:{A.relay[1]} ---")
    t0 = time.time()
    got = B.send_to(A.relay, b"echo-from-B")
    dt = (time.time()-t0)*1000
    if got == b"echo-from-B":
        print(f"RESULT: B->A relay forwarding OK ({dt:.0f}ms)")
    else:
        print(f"RESULT: B->A FAILED got={got!r}")

if __name__ == '__main__':
    main()
