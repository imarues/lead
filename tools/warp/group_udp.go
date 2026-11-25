package main

/*
#include <stdlib.h>
*/
import "C"

import (
 "encoding/json"
 "errors"
 "net"
 "net/netip"
 "strconv"
 "strings"
 "sync"
 "time"
)

// Each ICE candidate has its own loopback UDP relay. A different tunneled
// UDP socket is used for each native WebRTC source tuple. DTLS/SRTP/STUN
// packets are forwarded unchanged; the server fingerprint and ICE credentials
// remain those received from Telegram.
const maxGroupCandidates = 24
const maxGroupSources = 16
const groupIdleTimeout = 90 * time.Second

type groupPacketFlow struct {
 remote net.Conn
 last time.Time
}
type groupUDPRelay struct {
 local *net.UDPConn
 target netip.AddrPort
 dial func(netip.AddrPort)(net.Conn,error)
 mu sync.Mutex
 flows map[netip.AddrPort]*groupPacketFlow
 localIPs map[netip.Addr]bool
 closed bool
}

func newGroupRelay(target netip.AddrPort, dial func(netip.AddrPort)(net.Conn,error))(*groupUDPRelay,error) {
 // Bind only to loopback, never expose a public or LAN UDP proxy.
 family, ip := "udp4", net.IPv4(127,0,0,1)
 if target.Addr().Is6(){family,ip="udp6",net.IPv6loopback}
 listener,e:=net.ListenUDP(family,&net.UDPAddr{IP:ip})
 if e!=nil{return nil,e}
 localIPs:=make(map[netip.Addr]bool)
 if addrs,e:=net.InterfaceAddrs();e==nil{
  for _,a:=range addrs{
   if p,e:=netip.ParsePrefix(a.String());e==nil{localIPs[p.Addr().Unmap()]=true}
  }
 }
 r:=&groupUDPRelay{local:listener,target:target,dial:dial,flows:make(map[netip.AddrPort]*groupPacketFlow),localIPs:localIPs}
 go r.run()
 return r,nil
}
func (r *groupUDPRelay) close(){
 r.mu.Lock();defer r.mu.Unlock()
 if r.closed{return}
 r.closed=true
 r.local.Close()
 for _,f:=range r.flows{f.remote.Close()}
 r.flows=make(map[netip.AddrPort]*groupPacketFlow)
}
func (r *groupUDPRelay) remove(src netip.AddrPort,f *groupPacketFlow){
 r.mu.Lock();defer r.mu.Unlock()
 if r.flows[src]==f{delete(r.flows,src)}
 f.remote.Close()
}
func (r *groupUDPRelay) receive(src netip.AddrPort,f *groupPacketFlow){
 defer r.remove(src,f)
 buf:=make([]byte,65535)
 for {
  f.remote.SetReadDeadline(time.Now().Add(groupIdleTimeout))
  n,e:=f.remote.Read(buf);if e!=nil{return}
  r.mu.Lock();if r.closed{r.mu.Unlock();return};f.last=time.Now();r.mu.Unlock()
  if _,e=r.local.WriteToUDPAddrPort(buf[:n],src);e!=nil{return}
 }
}
func (r *groupUDPRelay) flow(src netip.AddrPort)(*groupPacketFlow,error){
 r.mu.Lock();defer r.mu.Unlock()
 if r.closed{return nil,net.ErrClosed}
 if f:=r.flows[src];f!=nil{f.last=time.Now();return f,nil}
 for k,f:=range r.flows{if time.Since(f.last)>groupIdleTimeout{f.remote.Close();delete(r.flows,k)}}
 if len(r.flows)>=maxGroupSources{return nil,errors.New("too many UDP flows")}
 remote,e:=r.dial(r.target);if e!=nil{return nil,e}
 f:=&groupPacketFlow{remote:remote,last:time.Now()}
 r.flows[src]=f
 go r.receive(src,f)
 return f,nil
}
func (r *groupUDPRelay) run(){
 defer r.close()
 buf:=make([]byte,65535)
 for {
  n,src,e:=r.local.ReadFromUDPAddrPort(buf);if e!=nil{return}
  // Other local processes cannot forward arbitrary destinations; destination
  // is fixed by the authenticated group call signaling payload.
  if !src.Addr().IsLoopback()&&!r.localIPs[src.Addr().Unmap()]{continue}
  f,e:=r.flow(src);if e!=nil{continue}
  f.remote.SetWriteDeadline(time.Now().Add(2*time.Second))
  if _,e=f.remote.Write(buf[:n]);e!=nil{r.remove(src,f)}
 }
}

type groupRelaySet struct {
 tunnel *tunnel
 relays []*groupUDPRelay
}

var groupSets=make(map[string]*groupRelaySet) // protected by stateMu
func closeGroupSet(token string){
 if s:=groupSets[token];s!=nil{
  delete(groupSets,token)
  for _,r:=range s.relays{r.close()}
 }
}
func closeAllGroupSets(){
 for token:=range groupSets{closeGroupSet(token)}
}

// The native group engine receives a JSON transport.candidates array. Keep
// all other fields and types unchanged. Refuse incomplete rewrites rather
// than silently routing a different candidate outside the selected tunnel.
func rewriteGroupPayload(raw string, relay func(netip.AddrPort)(netip.AddrPort,error))(string,error){
 var root map[string]json.RawMessage
 if e:=json.Unmarshal([]byte(raw),&root);e!=nil{return "",e}
 var transport map[string]json.RawMessage
 if e:=json.Unmarshal(root["transport"],&transport);e!=nil{return "",e}
 var candidates []map[string]json.RawMessage
 if e:=json.Unmarshal(transport["candidates"],&candidates);e!=nil{return "",e}
 if len(candidates)==0||len(candidates)>maxGroupCandidates{return "",errors.New("unsupported candidate count")}
 rewritten:=make([]map[string]json.RawMessage,0,len(candidates))
 for _,c:=range candidates{
  var proto,host,portText string
  if json.Unmarshal(c["protocol"],&proto)!=nil||!strings.EqualFold(proto,"udp"){continue}
  if json.Unmarshal(c["ip"],&host)!=nil{continue}
  ip,e:=netip.ParseAddr(host);if e!=nil{continue}
  ip=ip.Unmap()
  if !ip.IsGlobalUnicast()||ip.IsPrivate()||ip.IsLoopback()||ip.IsLinkLocalUnicast()||ip.Zone()!=""{continue}
  stringPort:=json.Unmarshal(c["port"],&portText)==nil
  if !stringPort{portText=string(c["port"])}
  n,e:=strconv.Atoi(portText);if e!=nil||n<1||n>65535{continue}
  local,e:=relay(netip.AddrPortFrom(ip,uint16(n)));if e!=nil{continue}
  c["ip"],_=json.Marshal(local.Addr().String())
  if stringPort{c["port"],_=json.Marshal(strconv.Itoa(int(local.Port())))}else{c["port"],_=json.Marshal(local.Port())}
  rewritten=append(rewritten,c)
 }
 if len(rewritten)==0{return "",errors.New("no routable UDP candidates")}
 transport["candidates"],_=json.Marshal(rewritten)
 root["transport"],_=json.Marshal(transport)
 result,e:=json.Marshal(root);return string(result),e
}

//export LeadWarpGroupRewrite
func LeadWarpGroupRewrite(token, payload *C.char) *C.char {
 if token==nil||payload==nil{return nil}
 id,raw:=C.GoString(token),C.GoString(payload)
 if len(id)==0||len(id)>128||len(raw)>1<<20{return nil}
 stateMu.Lock();defer stateMu.Unlock()
 t:=current
 if t==nil{return nil}
 if groupSets[id]==nil&&len(groupSets)>=8{return nil}
 set:=&groupRelaySet{tunnel:t}
 endpoints:=make(map[netip.AddrPort]netip.AddrPort)
 result,e:=rewriteGroupPayload(raw,func(target netip.AddrPort)(netip.AddrPort,error){
  if p,ok:=endpoints[target];ok{return p,nil}
  r,e:=newGroupRelay(target,func(target netip.AddrPort)(net.Conn,error){
   // Dial only inside WireGuard's userspace network stack.
   return t.stack.DialUDP(nil,net.UDPAddrFromAddrPort(target))
  })
  if e!=nil{return netip.AddrPort{},e}
  set.relays=append(set.relays,r)
  local:=r.local.LocalAddr().(*net.UDPAddr).AddrPort()
  endpoints[target]=local
  return local,nil
 })
 if e!=nil{
  for _,r:=range set.relays{r.close()}
  return nil
 }
 closeGroupSet(id)
 groupSets[id]=set
 return C.CString(result)
}

//export LeadWarpGroupClose
func LeadWarpGroupClose(token *C.char){
 if token==nil{return}
 stateMu.Lock();defer stateMu.Unlock()
 closeGroupSet(C.GoString(token))
}

