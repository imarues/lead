package main

import (
 "encoding/json"
 "net"
 "net/netip"
 "testing"
 "time"
)

func TestGroupPayloadRewrite(t *testing.T){
 input:=`{"transport":{"ufrag":"abc","pwd":"test","fingerprints":[{"hash":"sha-256","fingerprint":"00"}],"candidates":[{"ip":"192.0.2.10","port":"32000","protocol":"udp","foundation":"1"},{"ip":"2001:db8::1","port":32001,"protocol":"udp"},{"ip":"127.0.0.1","port":"7","protocol":"udp"},{"ip":"192.0.2.2","port":"99","protocol":"tcp"}]},"audio":{"endpoint":"unchanged"}}`
 n:=0
 out,e:=rewriteGroupPayload(input,func(target netip.AddrPort)(netip.AddrPort,error){
  n++
  if target.Addr().Is6(){return netip.MustParseAddrPort("[::1]:45001"),nil}
  return netip.MustParseAddrPort("127.0.0.1:45000"),nil
 })
 if e!=nil||n!=2{t.Fatalf("rewrite: %v; count %d",e,n)}
 var result struct {
  Transport struct{
   Ufrag string
   Pwd string
   Fingerprints []map[string]string
   Candidates []map[string]json.RawMessage
  }
  Audio map[string]string
 }
 if e=json.Unmarshal([]byte(out),&result);e!=nil{t.Fatal(e)}
 if result.Transport.Ufrag!="abc"||result.Transport.Pwd!="test"||result.Audio["endpoint"]!="unchanged"||len(result.Transport.Fingerprints)!=1{t.Fatal("changed signaling metadata")}
 c:=result.Transport.Candidates
 if len(c)!=2||string(c[0]["ip"])!="\"127.0.0.1\""||string(c[0]["port"])!="\"45000\""||string(c[1]["port"])!="45001"{t.Fatal("incorrect candidate encoding")}
}

func TestGroupRelayRoundTrip(t *testing.T){
 server,e:=net.ListenUDP("udp4",&net.UDPAddr{IP:net.IPv4(127,0,0,1)})
 if e!=nil{t.Fatal(e)}
 defer server.Close()
 go func(){
  buf:=make([]byte,1500)
  for {n,a,e:=server.ReadFromUDP(buf);if e!=nil{return};server.WriteToUDP(buf[:n],a)}
 }()
 r,e:=newGroupRelay(netip.MustParseAddrPort("192.0.2.10:32000"),func(netip.AddrPort)(net.Conn,error){
  return net.DialUDP("udp4",nil,server.LocalAddr().(*net.UDPAddr))
 })
 if e!=nil{t.Fatal(e)}
 defer r.close()
 for i:=0;i<2;i++{
  c,e:=net.DialUDP("udp4",nil,r.local.LocalAddr().(*net.UDPAddr))
  if e!=nil{t.Fatal(e)}
  defer c.Close()
  c.SetDeadline(time.Now().Add(3*time.Second))
  payload:=[]byte{0,1,2,3,byte(i)}
  if _,e=c.Write(payload);e!=nil{t.Fatal(e)}
  buf:=make([]byte,64)
  n,e:=c.Read(buf)
  if e!=nil||string(buf[:n])!=string(payload){t.Fatalf("roundtrip: %v",e)}
 }
}
