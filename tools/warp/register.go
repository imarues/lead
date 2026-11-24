package main

/*
#include <stdlib.h>
*/
import "C"

import (
 "bytes"
 "crypto/ecdh"
 "crypto/rand"
 "encoding/base64"
 "encoding/json"
 "fmt"
 "io"
 "net"
 "net/http"
 "net/netip"
 "strconv"
 "strings"
 "time"
)

type registrationReply struct {
 Config struct {
  Interface struct {
   Addresses struct {
    V4 string `json:"v4"`
    V6 string `json:"v6"`
   } `json:"addresses"`
  } `json:"interface"`
  Peers []struct {
   PublicKey string `json:"public_key"`
   Endpoint struct {
    Host string `json:"host"`
    V4 string `json:"v4"`
    V6 string `json:"v6"`
    Ports []int `json:"ports"`
   } `json:"endpoint"`
  } `json:"peers"`
 } `json:"config"`
}

func registrationAddress(s string, ipv6 bool) (string,bool) {
 if p,e:=netip.ParsePrefix(s);e==nil {s=p.Addr().String()}
 a,e:=netip.ParseAddr(s)
 if e!=nil || a.Is6()!=ipv6 || a.Zone()!="" || a.IsUnspecified() || a.IsLoopback() {return "",false}
 bits:=32;if ipv6 {bits=128}
 return netip.PrefixFrom(a,bits).String(),true
}

func buildRegisteredProfile(private string, r registrationReply) (string,error) {
 if _,e:=key(private);e!=nil{return "",e}
 a:=r.Config.Interface.Addresses
 var addresses,allowed []string
 if v,ok:=registrationAddress(a.V4,false);ok {addresses=append(addresses,v);allowed=append(allowed,"0.0.0.0/0")}
 if v,ok:=registrationAddress(a.V6,true);ok {addresses=append(addresses,v);allowed=append(allowed,"::/0")}
 if len(addresses)==0{return "",fmt.Errorf("missing tunnel addresses")}
 for _,p:=range r.Config.Peers {
  if _,e:=key(p.PublicKey);e!=nil{continue}
  port:=2408
  for _,n:=range p.Endpoint.Ports {if n>0&&n<=65535 {port=n;break}}
  // Prefer an explicit IPv4 endpoint on mobile, then host or IPv6.
  for _,candidate:=range []string{p.Endpoint.V4,p.Endpoint.Host,p.Endpoint.V6} {
   host:=strings.TrimSpace(candidate);if host==""{continue}
   chosenPort:=port
   if h,ps,e:=net.SplitHostPort(host);e==nil {
    n,e:=strconv.Atoi(ps);if e!=nil||n<1||n>65535{continue};host=h;chosenPort=n
   }
   if strings.ContainsAny(host,"\r\n\t /?#@") {continue}
   endpoint:=net.JoinHostPort(strings.Trim(host,"[]"),strconv.Itoa(chosenPort))
   result:=fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = 1.1.1.1\nMTU = 1280\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s\nEndpoint = %s\nPersistentKeepalive = 25\n",private,strings.Join(addresses,", "),p.PublicKey,strings.Join(allowed,", "),endpoint)
   if _,e:=parse(result);e==nil{return result,nil}
  }
 }
 return "",fmt.Errorf("missing usable peer")
}

//export LeadWarpRegister
func LeadWarpRegister(status *C.int) *C.char {
 if status==nil{return nil}
 *status=-10
 // Only a public key is sent to the registration endpoint. The private key
 // is generated locally and returned to the caller for local Keychain storage.
 private,e:=ecdh.X25519().GenerateKey(rand.Reader);if e!=nil{return nil}
 public:=base64.StdEncoding.EncodeToString(private.PublicKey().Bytes())
 body,e:=json.Marshal(map[string]string{
  "key":public,"key_type":"curve25519","tunnel_type":"wireguard",
  "locale":"en_US","model":"Lead iOS","os_version":"16.0.0",
  "install_id":"","fcm_token":"","serial_number":"",
  "tos":time.Now().UTC().Format(time.RFC3339Nano),
 });if e!=nil{return nil}
 req,e:=http.NewRequest("POST","https://api.cloudflareclient.com/v0a5641/reg",bytes.NewReader(body));if e!=nil{return nil}
 req.Header.Set("Content-Type","application/json; charset=UTF-8")
 req.Header.Set("User-Agent","Lead-WARP-experimental/1.0")
 req.Header.Set("CF-Client-Version","a-6.38.9-5641")
 tr:=&http.Transport{TLSHandshakeTimeout:10*time.Second,DisableKeepAlives:true}
 defer tr.CloseIdleConnections()
 client:=&http.Client{Transport:tr,Timeout:20*time.Second,CheckRedirect:func(*http.Request,[]*http.Request)error{return http.ErrUseLastResponse}}
 resp,e:=client.Do(req);if e!=nil{*status=-11;return nil}
 defer resp.Body.Close()
 if resp.StatusCode!=200 && resp.StatusCode!=201 {*status=C.int(resp.StatusCode);return nil}
 data,e:=io.ReadAll(io.LimitReader(resp.Body,1<<20));if e!=nil{*status=-12;return nil}
 var r registrationReply
 if e=json.Unmarshal(data,&r);e!=nil{*status=-12;return nil}
 profile,e:=buildRegisteredProfile(base64.StdEncoding.EncodeToString(private.Bytes()),r);if e!=nil{*status=-12;return nil}
 *status=0
 return C.CString(profile)
}
