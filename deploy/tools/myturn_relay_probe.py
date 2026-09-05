#!/usr/bin/env python3
"""TURN 中继端口"入站可达"实测（在公网观测点运行，如阿里云）。

myturn_probe.py 只能证明"能分配到中继端口"；本脚本证明"远端 peer 能主动
把 UDP 包打进中继端口"——即路由器/防火墙对中继端口段的 DNAT 真实生效。

用法:
    python3 myturn_relay_probe.py <turn_host> <peer_ip> [user] [password]

流程（RFC 5766，单连接自洽）:
  1) TURN over TCP 连 <turn_host>:3478，鉴权 Allocate（UDP 中继）
  2) CreatePermission 放行 <peer_ip>（探测包将以该 IP 作为源地址到达）
  3) 从本机另发一个 UDP 包到中继地址（模拟远端 peer 的入站媒体）
  4) 若该包经 Data Indication 从 TCP 连接原样返回 → 中继段 DNAT 生效 ✓

退出码 0 = 中继端口可从公网入站。
"""
import hashlib, hmac, os, socket, struct, sys

MAGIC = 0x2112A442
ALLOCATE = 0x0003
CREATE_PERMISSION = 0x0008
DATA_INDICATION = 0x0017
XOR_RELAYED = 0x0016
XOR_PEER = 0x0012
USERNAME = 0x0006
REALM = 0x0014
NONCE = 0x0015
MESSAGE_INTEGRITY = 0x0008
REQUESTED_TRANSPORT = 0x0019
ERROR_CODE = 0x0009
DATA = 0x0013  # RFC 5766: DATA 属性类型是 0x0013（0x0010 保留）

PROBE_PAYLOAD = b"MYPHONE-RELAY-PROBE"


def attr(t, v):
    v = v + b'\x00' * ((4 - len(v) % 4) % 4)
    return struct.pack('>HH', t, len(v)) + v

def msg(mtype, txn, attrs=b''):
    return struct.pack('>HHI', mtype, len(attrs), MAGIC) + txn + attrs

def parse(stun):
    out = {}
    off = 20
    while off + 4 <= len(stun):
        t, ln = struct.unpack('>HH', stun[off:off+4])
        v = stun[off+4:off+4+ln]
        out[t] = v
        off += 4 + ln + ((4 - ln % 4) % 4)
    return out

def xor_addr(v):
    port = ((v[2] ^ (MAGIC >> 24)) << 8) | (v[3] ^ ((MAGIC >> 16) & 0xFF))
    ip = '.'.join(str(b ^ ((MAGIC >> ((3-i)*8)) & 0xff)) for i, b in enumerate(v[4:8]))
    return ip, port

def pack_xor_addr(ip, port):
    b = bytes(int(x) for x in ip.split('.'))
    eport = port ^ (MAGIC >> 16)
    xip = bytes(x ^ ((MAGIC >> ((3-i)*8)) & 0xff) for i, x in enumerate(b))
    return b'\x00' + struct.pack('>H', eport) + xip

def with_integrity(mtype, txn, attrs, user, realm, nonce, key):
    base = (attr(USERNAME, user.encode()) + attr(REALM, realm.encode()) +
            attr(NONCE, nonce.encode()) + attrs)
    length = len(base) + 24  # coturn: Length 含 MI 不含 FINGERPRINT
    hdr = struct.pack('>HHI', mtype, length, MAGIC) + txn + base
    pad = b'\x00' * ((4 - (len(hdr) + 4) % 4) % 4)
    mi = hmac.new(key, hdr + pad, hashlib.sha1).digest()
    return hdr + attr(MESSAGE_INTEGRITY, mi)

def errcode(a):
    ec = a[ERROR_CODE]
    return ec[2] * 100 + ec[3]


class TurnUdp:
    """客户端走 UDP 传输（与真机 ICE 的 TURN 用法一致）。"""

    def __init__(self, host, port, user, pw, timeout=6):
        self.user, self.pw = user, pw
        self.realm = host
        self.nonce = ''
        self.key = b''
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        self.addr = (host, port)

    def recv(self):
        data, _ = self.sock.recvfrom(65535)
        mtype, ln, magic = struct.unpack('>HHI', data[:8])
        return mtype, parse(data)

    def request(self, mtype, attrs, authed):
        txn = os.urandom(12)
        if authed:
            raw = with_integrity(mtype, txn, attrs, self.user,
                                 self.realm, self.nonce, self.key)
        else:
            raw = msg(mtype, txn, attrs)
        self.sock.sendto(raw, self.addr)
        return self.recv()

    def allocate(self):
        ra = attr(REQUESTED_TRANSPORT, b'\x11\x00\x00\x00')
        mtype, a = self.request(ALLOCATE, ra, authed=False)
        if ERROR_CODE in a and errcode(a) == 401:
            self.realm = a[REALM].decode()
            self.nonce = a[NONCE].decode()
            self.key = hashlib.md5(f"{self.user}:{self.realm}:{self.pw}".encode()).digest()
            mtype, a = self.request(ALLOCATE, ra, authed=True)
        if ERROR_CODE in a:
            raise RuntimeError(f'allocate error {errcode(a)}')
        if XOR_RELAYED not in a:
            raise RuntimeError(f'allocate: no XOR-RELAYED (attrs={list(a.keys())})')
        return xor_addr(a[XOR_RELAYED])

    def create_permission(self, peer_ip):
        attrs = attr(XOR_PEER, pack_xor_addr(peer_ip, 9))
        mtype, a = self.request(CREATE_PERMISSION, attrs, authed=True)
        if ERROR_CODE in a:
            raise RuntimeError(f'create-permission error {errcode(a)}')


class TurnTcp:
    def __init__(self, host, port, user, pw, timeout=6):
        self.user, self.pw = user, pw
        self.realm = host  # 占位, 401 后更新
        self.nonce = ''
        self.key = b''
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)

    def _recv_exact(self, n):
        buf = b''
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError('TCP closed by server')
            buf += chunk
        return buf

    def recv(self):
        hdr = self._recv_exact(20)
        mtype, ln, magic = struct.unpack('>HHI', hdr[:8])
        body = self._recv_exact(ln) if ln else b''
        return mtype, parse(hdr + body)

    def request(self, mtype, attrs, authed):
        txn = os.urandom(12)
        if authed:
            raw = with_integrity(mtype, txn, attrs, self.user,
                                 self.realm, self.nonce, self.key)
        else:
            raw = msg(mtype, txn, attrs)
        self.sock.sendall(raw)
        return self.recv()

    def allocate(self):
        ra = attr(REQUESTED_TRANSPORT, b'\x11\x00\x00\x00')
        mtype, a = self.request(ALLOCATE, ra, authed=False)
        if ERROR_CODE in a and errcode(a) == 401:
            self.realm = a[REALM].decode()
            self.nonce = a[NONCE].decode()
            self.key = hashlib.md5(f"{self.user}:{self.realm}:{self.pw}".encode()).digest()
            mtype, a = self.request(ALLOCATE, ra, authed=True)
        if ERROR_CODE in a:
            raise RuntimeError(f'allocate error {errcode(a)}')
        if XOR_RELAYED not in a:
            raise RuntimeError(f'allocate: no XOR-RELAYED (attrs={list(a.keys())})')
        return xor_addr(a[XOR_RELAYED])

    def create_permission(self, peer_ip):
        attrs = attr(XOR_PEER, pack_xor_addr(peer_ip, 9))
        mtype, a = self.request(CREATE_PERMISSION, attrs, authed=True)
        if ERROR_CODE in a:
            raise RuntimeError(f'create-permission error {errcode(a)}')


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    args = [a for a in sys.argv[1:]]
    use_tcp = '--tcp' in args
    args = [a for a in args if a != '--tcp']
    host = args[0]
    peer_ip = args[1]
    user = args[2] if len(args) > 2 else 'myphone'
    pw = args[3] if len(args) > 3 else ''

    t = (TurnTcp if use_tcp else TurnUdp)(host, 3478, user, pw)
    relay_ip, relay_port = t.allocate()
    print(f"[TURN] 分配中继: {relay_ip}:{relay_port} (客户端传输: {'TCP' if use_tcp else 'UDP'})")
    t.create_permission(peer_ip)
    print(f"[TURN] 已为 {peer_ip} 创建权限")

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.sendto(PROBE_PAYLOAD, (relay_ip, relay_port))
    print(f"[UDP ] 已向中继端口发送探测包 ({len(PROBE_PAYLOAD)}B)，等待回流 ...")

    try:
        while True:
            mtype, a = t.recv()
            if '--debug' in sys.argv:
                print(f"[DBG ] recv type=0x{mtype:04x} attrs={list(a.keys())}")
            if mtype == DATA_INDICATION and DATA in a:
                if a[DATA] == PROBE_PAYLOAD:
                    print(f"[DATA] 探测包经中继原样返回: {a[DATA]!r}")
                    print("\nRESULT: PASS ✓  中继端口可从公网入站")
                    sys.exit(0)
                print(f"[DATA] 收到其他数据: {a[DATA]!r}")
    except socket.timeout:
        print("[DATA] 超时: 探测包未能穿过中继端口(中继段 DNAT 未生效?)")
        print("\nRESULT: FAIL ✗")
        sys.exit(1)


if __name__ == '__main__':
    main()
