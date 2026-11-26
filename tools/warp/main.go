// Experimental application-local WireGuard tunnel. No OS VPN/TUN interface.
// The supplied profile is never logged or persisted by this component.
package main

/*
#include <stdint.h>
*/
import "C"

import (
 "context"
 "encoding/base64"
 "encoding/binary"
 "encoding/hex"
 "errors"
 "fmt"
 "io"
 "net"
 "net/http"
 "net/netip"
 "strconv"
 "strings"
 "sync"
 "time"

 "golang.zx2c4.com/wireguard/conn"
 "golang.zx2c4.com/wireguard/device"
 "golang.zx2c4.com/wireguard/tun/netstack"
)

type profile struct {
 local, dns []netip.Addr
 mtu int
 ipc string
}

func key(s string) (string,error) {
 b,e:=base64.StdEncoding.DecodeString(s)
 if e!=nil || len(b)!=32 { return "",errors.New("invalid key") }
 return hex.EncodeToString(b),nil
}

func parse(raw string) (profile,error) {
 p:=profile{mtu:1280}
 section:=""
 interfaceFields:=map[string]string{}
 peer:=map[string]string{}
 for _,line:=range strings.Split(raw,"\n") {
  line=strings.TrimSpace(strings.SplitN(line,"#",2)[0])
  if line=="" {continue}
  if strings.HasPrefix(line,"[") {
   if line=="[Interface]" && section=="" {section="i";continue}
   if line=="[Peer]" && section=="i" {section="p";continue}
   return p,errors.New("one peer required")
  }
  k,v,ok:=strings.Cut(line,"=")
  if !ok {return p,errors.New("invalid profile")}
  k,v=strings.TrimSpace(k),strings.TrimSpace(v)
  var dst map[string]string
  switch section {case "i":dst=interfaceFields;case "p":dst=peer;default:return p,errors.New("missing section")}
  if _,exists:=dst[k];exists {return p,errors.New("duplicate field")}
  dst[k]=v
 }
 for _,v:=range strings.Split(interfaceFields["Address"],",") {
  n,e:=netip.ParsePrefix(strings.TrimSpace(v))
  if e!=nil {return p,e}
  p.local=append(p.local,n.Addr())
 }
 if s:=interfaceFields["DNS"];s!="" {
  for _,v:=range strings.Split(s,",") {
   n,e:=netip.ParseAddr(strings.TrimSpace(v));if e!=nil{return p,e}
   p.dns=append(p.dns,n)
  }
 } else {p.dns=[]netip.Addr{netip.MustParseAddr("1.1.1.1")}}
 if s:=interfaceFields["MTU"];s!="" {
  n,e:=strconv.Atoi(s);if e!=nil||n<1280||n>1500{return p,errors.New("invalid MTU")};p.mtu=n
 }
 private,e:=key(interfaceFields["PrivateKey"]);if e!=nil{return p,e}
 public,e:=key(peer["PublicKey"]);if e!=nil{return p,e}
 endpoint,e:=net.ResolveUDPAddr("udp",peer["Endpoint"]);if e!=nil||endpoint.Port==0{return p,errors.New("invalid endpoint")}
 var ipc strings.Builder
 fmt.Fprintf(&ipc,"private_key=%s\npublic_key=%s\nendpoint=%s\n",private,public,endpoint.String())
 if s:=peer["PresharedKey"];s!="" { k,e:=key(s);if e!=nil{return p,e};fmt.Fprintf(&ipc,"preshared_key=%s\n",k)}
 for _,v:=range strings.Split(peer["AllowedIPs"],",") {
  n,e:=netip.ParsePrefix(strings.TrimSpace(v));if e!=nil{return p,e}
  fmt.Fprintf(&ipc,"allowed_ip=%s\n",n.Masked().String())
 }
 keep:=25
 if s:=peer["PersistentKeepalive"];s!="" {n,e:=strconv.Atoi(s);if e!=nil||n<0||n>65535{return p,errors.New("invalid keepalive")};keep=n}
 fmt.Fprintf(&ipc,"persistent_keepalive_interval=%d\n",keep)
 p.ipc=ipc.String()
 return p,nil
}

type tunnel struct {
 dev *device.Device
 stack *netstack.Net
 listener net.Listener
 user,pass string
 mu sync.Mutex
 closed bool
 clients map[net.Conn]struct{}
}

var stateMu sync.Mutex
var current *tunnel

func (t *tunnel) close() {
 t.mu.Lock()
 t.closed=true
 if t.listener!=nil {t.listener.Close()}
 for c:=range t.clients {c.Close()}
 t.mu.Unlock()
 t.dev.Close()
}

func (t *tunnel) run() {
 for {
  c,e:=t.listener.Accept();if e!=nil{return}
  t.mu.Lock()
  if t.closed {t.mu.Unlock();c.Close();return}
  if len(t.clients)>=64 {t.mu.Unlock();c.Close();continue}
  t.clients[c]=struct{}{}
  t.mu.Unlock()
  go func(c net.Conn){
   defer func(){c.Close();t.mu.Lock();delete(t.clients,c);t.mu.Unlock()}()
   t.serve(c)
  }(c)
 }
}

func read(c net.Conn,n int)([]byte,error){
 b:=make([]byte,n);_,e:=io.ReadFull(c,b);return b,e
}
func write(c net.Conn,b []byte)bool{n,e:=c.Write(b);return e==nil&&n==len(b)}
func (t *tunnel) serve(c net.Conn){
 c.SetDeadline(time.Now().Add(10*time.Second))
 h,e:=read(c,2);if e!=nil||h[0]!=5||h[1]==0{return}
 methods,e:=read(c,int(h[1]));if e!=nil{return}
 supported:=false;for _,m:=range methods{if m==2{supported=true}}
 if !supported{write(c,[]byte{5,255});return}
 if !write(c,[]byte{5,2}){return}
 h,e=read(c,2);if e!=nil||h[0]!=1{return}
 u,e:=read(c,int(h[1]));if e!=nil{return}
 n,e:=read(c,1);if e!=nil{return}
 p,e:=read(c,int(n[0]));if e!=nil{return}
 if string(u)!=t.user||string(p)!=t.pass{write(c,[]byte{1,1});return}
 if !write(c,[]byte{1,0}){return}
 h,e=read(c,4);if e!=nil||h[0]!=5||h[2]!=0{return}
 fail:=func(code byte){write(c,[]byte{5,code,0,1,0,0,0,0,0,0})}
 if h[1]!=1 {fail(7);return} // TCP CONNECT only; UDP media integration is not implemented.
 var host string
 switch h[3]{
 case 1:b,e:=read(c,4);if e!=nil{return};host=net.IP(b).String()
 case 4:b,e:=read(c,16);if e!=nil{return};host=net.IP(b).String()
 case 3:b,e:=read(c,1);if e!=nil||b[0]==0{return};b,e=read(c,int(b[0]));if e!=nil{return};host=string(b)
 default:fail(8);return
 }
 b,e:=read(c,2);if e!=nil{return}
 port:=binary.BigEndian.Uint16(b);if port==0{fail(1);return}
 ctx,cancel:=context.WithTimeout(context.Background(),12*time.Second)
 remote,e:=t.stack.DialContext(ctx,"tcp",net.JoinHostPort(host,strconv.Itoa(int(port))))
 cancel();if e!=nil{fail(4);return}
 defer remote.Close()
 if !write(c,[]byte{5,0,0,1,0,0,0,0,0,0}){return}
 c.SetDeadline(time.Time{})
 done:=make(chan struct{})
 go func(){io.Copy(remote,c);remote.Close();close(done)}()
 io.Copy(c,remote);c.Close();remote.Close();<-done
}

func (t *tunnel) healthy(timeout time.Duration) bool {
 t.mu.Lock()
 closed:=t.closed
 t.mu.Unlock()
 if closed{return false}
 transport:=&http.Transport{DialContext:t.stack.DialContext,DisableKeepAlives:true}
 defer transport.CloseIdleConnections()
 client:=&http.Client{Transport:transport,Timeout:timeout,CheckRedirect:func(*http.Request,[]*http.Request)error{return http.ErrUseLastResponse}}
 resp,e:=client.Get("https://www.cloudflare.com/cdn-cgi/trace")
 if e!=nil{return false}
 defer resp.Body.Close()
 body,e:=io.ReadAll(io.LimitReader(resp.Body,16384))
 trace:="\n"+strings.TrimSpace(string(body))+"\n"
 return e==nil&&resp.StatusCode==200&&(strings.Contains(trace,"\nwarp=on\n")||strings.Contains(trace,"\nwarp=plus\n"))
}

//export LeadWarpHealthCheck
func LeadWarpHealthCheck() C.int {
 stateMu.Lock()
 t:=current
 stateMu.Unlock()
 if t!=nil&&t.healthy(8*time.Second){return 1}
 return 0
}

//export LeadWarpStart
func LeadWarpStart(config,user,pass *C.char) C.int {
 stateMu.Lock();defer stateMu.Unlock()
 if current!=nil{return -5}
 raw,u,pw:=C.GoString(config),C.GoString(user),C.GoString(pass)
 if len(raw)>65536||len(u)==0||len(pw)==0||len(u)>255||len(pw)>255{return -1}
 cfg,e:=parse(raw);if e!=nil{return -1}
 tun,stack,e:=netstack.CreateNetTUN(cfg.local,cfg.dns,cfg.mtu);if e!=nil{return -2}
 dev:=device.NewDevice(tun,conn.NewDefaultBind(),device.NewLogger(device.LogLevelSilent,""))
 t:=&tunnel{dev:dev,stack:stack,user:u,pass:pw,clients:make(map[net.Conn]struct{})}
 if e=dev.IpcSet(cfg.ipc);e!=nil{t.close();return -2}
 if e=dev.Up();e!=nil{t.close();return -2}
 // Confirm that the WireGuard stack actually reaches the service.
 if !t.healthy(18*time.Second){t.close();return -3}
 t.listener,e=net.Listen("tcp4","127.0.0.1:0");if e!=nil{t.close();return -4}
 current=t
 go t.run()
 return C.int(t.listener.Addr().(*net.TCPAddr).Port)
}

//export LeadWarpStop
func LeadWarpStop(){
 stateMu.Lock();defer stateMu.Unlock()
 closeAllGroupSets()
 if current!=nil{current.close();current=nil}
}

func main(){}
