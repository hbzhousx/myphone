//go:build linux || android
package main
// 验证 coturn 两个独立 TURN 客户端之间 relay→relay 转发是否工作。
//
// 背景(2026-08-08 实测):coturn 4.15.0 的 relay→relay 数据转发缺陷被本工具 + tcpdump
// 定位。结论:
//   - turnutils_uclient -y 的"成功"实为内部直连(流量不经过中继端口)
//   - 独立连接(本工具)的 SEND/ChannelData、奇偶端口、公网/内部地址,relay→relay 全部失败
//   - relay → 普通 UDP peer 转发正常(turnutils_uclient -e)
//   → 故障精确限定在 "relay → 另一个 TURN 分配的 relay socket" 这一跳。
//
// 复测用法:
//   go build -o rtcp_probe . && ./rtcp_probe <TURN密码>   # 需在能连到 TURN 的机器上
// 观察输出:若每对 "A got NOTHING",即 relay→relay 仍不工作(需升级 coturn 复测)。
import ("crypto/hmac";"crypto/sha1";"crypto/md5";"encoding/binary";"fmt";"net";"os";"time")
const MAGIC=0x2112A442
func attr(t uint16,v []byte)[]byte{for len(v)%4!=0{v=append(v,0)};o:=make([]byte,4);binary.BigEndian.PutUint16(o[0:2],t);binary.BigEndian.PutUint16(o[2:4],uint16(len(v)));return append(o,v...)}
func msg(mt uint16,txn []byte,attrs []byte)[]byte{o:=make([]byte,20);binary.BigEndian.PutUint16(o[0:2],mt);binary.BigEndian.PutUint16(o[2:4],uint16(len(attrs)));binary.BigEndian.PutUint32(o[4:8],MAGIC);copy(o[8:20],txn);return append(o,attrs...)}
func parse(b []byte)map[uint16][]byte{o:=map[uint16][]byte{};off:=20;for off+4<=len(b){t:=binary.BigEndian.Uint16(b[off:off+2]);ln:=int(binary.BigEndian.Uint16(b[off+2:off+4]));o[t]=b[off+4:off+4+ln];off+=4+ln+(4-ln%4)%4};return o}
func xaddr(ip string,port int)[]byte{ipa:=net.ParseIP(ip).To4();m:=uint32(MAGIC);xp:=port^int(MAGIC>>16);xi:=make([]byte,4);for i:=0;i<4;i++{xi[i]=ipa[i]^uint8((m>>(24-uint(i)*8))&0xff)};return append([]byte{0x01,byte(xp>>8),byte(xp&0xff)},xi...)}
func xorAddr(v []byte)(string,int){port:=binary.BigEndian.Uint16(v[2:4])^uint16(MAGIC>>16);ip:=make([]byte,4);m:=uint32(MAGIC);for i:=0;i<4;i++{ip[i]=v[4+i]^uint8((m>>(24-uint(i)*8))&0xff)};return net.IPv4(ip[0],ip[1],ip[2],ip[3]).String(),int(port)}
func withMI(mt uint16,txn []byte,attrs []byte,key []byte,realm,nonce,user string)[]byte{base:=append(attr(0x6,[]byte(user)),attr(0x14,[]byte(realm))...);base=append(base,attr(0x15,[]byte(nonce))...);base=append(base,attrs...);length:=len(base)+24;hdr:=make([]byte,20);binary.BigEndian.PutUint16(hdr[0:2],mt);binary.BigEndian.PutUint16(hdr[2:4],uint16(length));binary.BigEndian.PutUint32(hdr[4:8],MAGIC);copy(hdr[8:20],txn);full:=append(hdr,base...);for(len(full)+24)%4!=0{full=append(full,0)};mac:=hmac.New(sha1.New,key);mac.Write(full);return append(full,attr(0x8,mac.Sum(nil))...)}
type cli struct{c *net.UDPConn;realm,nonce,key string;relay string;relayp int}
func newCli(host string,port int)*cli{a,_:=net.ResolveUDPAddr("udp",fmt.Sprintf("%s:%d",host,port));c,_:=net.DialUDP("udp",nil,a);return &cli{c:c}}
func(k *cli)rt(p []byte,t time.Duration)([]byte,error){k.c.SetDeadline(time.Now().Add(t));k.c.Write(p);b:=make([]byte,4096);n,e:=k.c.Read(b);if e!=nil{return nil,e};return b[:n],nil}
func(k *cli)alloc(user,pw string)bool{txn:=[]byte("allocrelay01");f,e:=k.rt(msg(3,txn,attr(0x19,[]byte{0x11,0,0,0})),8*time.Second);if e!=nil{return false};a:=parse(f);k.realm=string(a[0x14]);k.nonce=string(a[0x15]);s:=md5.Sum([]byte(fmt.Sprintf("%s:%s:%s",user,k.realm,pw)));k.key=string(s[:]);au:=withMI(3,txn,attr(0x19,[]byte{0x11,0,0,0}),[]byte(k.key),k.realm,k.nonce,user);r,e:=k.rt(au,8*time.Second);if e!=nil{return false};a2:=parse(r);if x,ok:=a2[0x16];ok{ip,p:=xorAddr(x);k.relay,k.relayp=ip,p;return true};return false}
func(k *cli)perm(ip string)bool{txn:=[]byte("permission1");_,e:=k.rt(withMI(0x8,txn,attr(0x12,xaddr(ip,0)),[]byte(k.key),k.realm,k.nonce,"myphone"),8*time.Second);return e==nil}
func(k *cli)send(ip string,port int,payload []byte){txn:=[]byte("send00112233");attrs:=append(attr(0x12,xaddr(ip,port)),attr(0x13,payload)...);k.rt(withMI(0x16,txn,attrs,[]byte(k.key),k.realm,k.nonce,"myphone"),6*time.Second)}
// ChannelData 发送:RFC5766 通道消息,格式: 2B 通道号(0x4000起) + 2B 长度 + 数据
func(k *cli)channelSend(ch uint16,payload []byte){
	head:=make([]byte,4); binary.BigEndian.PutUint16(head[0:2],ch); binary.BigEndian.PutUint16(head[2:4],uint16(len(payload)))
	full:=append(head,payload...)
	k.c.Write(full) // ChannelData 不加密、不签名,直接发
}
func(k *cli)channelBind(ip string,port int,ch uint16)bool{
	txn:=[]byte("chbind000001"); attrs:=attr(0x12,xaddr(ip,port))
	_,e:=k.rt(withMI(0x9,txn,attrs,[]byte(k.key),k.realm,k.nonce,"myphone"),8*time.Second)
	return e==nil
}
func main(){host:="172.19.58.9";port:=3478;user:="myphone";pw:=os.Args[1]
	for i:=0;i<6;i++{
		a:=newCli(host,port); if !a.alloc(user,pw){fmt.Printf("PAIR%d A alloc fail\n",i);continue}
		b:=newCli(host,port); if !b.alloc(user,pw){fmt.Printf("PAIR%d B alloc fail\n",i);continue}
		fmt.Printf("PAIR%d A.relay=%s:%d (parity %d)  B.relay=%s:%d\n",i,a.relay,a.relayp,a.relayp%2,b.relay,b.relayp)
		// 用 ChannelData(真机 libwebrtc 的默认媒体路径)
		// 用 INTERNAL relay 地址(172.19.58.9:port)而非公网通告地址
		ainternal := "172.19.58.9"
		if b.channelBind(ainternal,a.relayp,0x4000) {
			b.channelSend(0x4000, []byte("channel-internal-test"))
			fmt.Printf("PAIR%d B channel-bound + sent to A INTERNAL relay %s:%d\n", i, ainternal, a.relayp)
		} else {
			fmt.Printf("PAIR%d B channelBind FAILED\n", i)
		}
		// A 端尝试接收 1s,看 B 的数据是否到达
		a.c.SetDeadline(time.Now().Add(1200*time.Millisecond))
		buf:=make([]byte,4096)
		n,e:=a.c.Read(buf)
		if e==nil { fmt.Printf("PAIR%d A RECEIVED %d bytes: %q\n", i, n, buf[:n]) } else { fmt.Printf("PAIR%d A got NOTHING (e=%v)\n", i, e) }
	}
}
