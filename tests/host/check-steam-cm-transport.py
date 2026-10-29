#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
# Adapted from kuscholar/iDeck e3d845e, tests/host/check-steam-cm-transport.py.
"""Run actual endpoint selection and connection retry/cleanup with scripted failures."""
from pathlib import Path
import subprocess,tempfile,os
r=Path(__file__).resolve().parents[2]
core=r/'app/Madeira/SwiftSteam/Core'
s=(core/'SteamConnection.swift').read_text()
def function(signature):
 a=s.index(signature);return s[a:s.index('\n    }',a)+6]
methods='\n'.join(function(x) for x in ['    func connect() async throws {','    private func clearTransport() {','    func disconnect() {','    private func handleDisconnect(task:', '    private func received('])
methods=methods.replace('URLSessionWebSocketTask', 'FakeTask')
error=(core/'SteamError.swift').read_text();servers=(core/'CMServerList.swift').read_text()
h=r'''
import Foundation
enum SteamLog {static func trace(_ s:String){}; static func event(_ s:String){}}
extension CMServerList {
 func seed(_ count:Int){servers=(0..<count).map{CMServer(host:"cm\($0).steampowered.com",port:443)};lastFetched=Date()}
 func failures()->[Int]{servers.map{$0.failCount}}
}
final class FakeTask {
 enum CloseCode{case goingAway}
 enum Message{case data(Data),string(String)}
 var cancelled=false
 func cancel(with:CloseCode,reason:Data?){cancelled=true}
}
final class FakeSession {var invalidated=false;func invalidateAndCancel(){invalidated=true}}
final class Sink {var messages:[Data]=[];var disconnections=0}
actor Harness {
 let serverList:CMServerList
 var currentEndpoint:String?,activeConnect:UUID?
 var webSocketTask:FakeTask?,urlSession:FakeSession?
 var attempts:[String]=[],tasks:[FakeTask]=[],sessions:[FakeSession]=[]
 var receives=0;var codes:[Int?];var disconnectHandler:((Error?)->Void)?;var messageHandler:((Data)->Void)?
 let sink:Sink
 var holdNext=false;var release:CheckedContinuation<Void,Never>?
 var waiters:[CheckedContinuation<Void,Never>]=[]
 init(_ list:CMServerList,_ codes:[Int?]){
  serverList=list;self.codes=codes
  let sink=Sink();self.sink=sink
  messageHandler={sink.messages.append($0)}
  disconnectHandler={_ in sink.disconnections+=1}
 }
 func scheduleReceive(_ task:FakeTask){receives+=1}
 private func connect(to server:CMServerList.CMServer) async throws {
  currentEndpoint=server.endpoint;attempts.append(server.endpoint)
  let task=FakeTask(),session=FakeSession();tasks.append(task);sessions.append(session);webSocketTask=task;urlSession=session
  let code=codes.removeFirst()
  if holdNext {
   holdNext=false
   await withCheckedContinuation { continuation in
    release=continuation
    for waiter in waiters {waiter.resume()};waiters=[]
   }
  }
  if let code {throw NSError(domain:NSURLErrorDomain,code:code,userInfo:[NSLocalizedDescriptionKey:"secret-token",NSURLErrorFailingURLErrorKey:URL(string:"https://private.invalid/?secret-token")!])}
 }
'''+methods+r'''
 func staleDisconnect(){handleDisconnect(task:tasks[0],error:nil)}
 func staleMessage(){received(.success(.data(Data([1]))),from:tasks[0])}
 func currentMessage(){received(.success(.data(Data([2]))),from:tasks.last!)}
 func currentDisconnect(){received(.failure(NSError(domain:NSPOSIXErrorDomain,code:57)),from:tasks.last!)}
 func delivered()->[Data]{sink.messages}
 func disconnected()->Int{sink.disconnections}
 func holdAttempt(){holdNext=true}
 func waitUntilHeld() async {
  if release != nil {return}
  await withCheckedContinuation {waiters.append($0)}
 }
 func releaseAttempt(){let continuation=release;release=nil;continuation?.resume()}
 func status()->(Int,Int,Int,Int){(attempts.count,receives,tasks.filter{$0.cancelled}.count,sessions.filter{$0.invalidated}.count)}
}
@main struct Main {
 static func main() async throws {
  for code in [-1201,-1202,-1203,-1204,-1205,-1206,-999,-1009] {assert(!SteamCMTransportPolicy.canTryAnotherServer(URLError(URLError.Code(rawValue:code))))}
  for code in [-1001,-1003,-1004,-1005,-1006,-1200] {
   assert(SteamCMTransportPolicy.canTryAnotherServer(URLError(URLError.Code(rawValue:code))))
  }
  let unknown=NSError(domain:"secret-token",code:42,userInfo:[NSLocalizedDescriptionKey:"secret-token"])
  assert(!SteamCMTransportPolicy.canTryAnotherServer(unknown))
  assert(SteamCMTransportPolicy.sanitized(unknown)==SteamError.transportFailed(domain:"other",code:42))
  let unhealthy=CMServerList();await unhealthy.seed(2)
  for _ in 0..<3 {
   await unhealthy.markFailed(endpoint:"cm0.steampowered.com:443")
   await unhealthy.markFailed(endpoint:"cm1.steampowered.com:443")
  }
  let reset=try await unhealthy.getServer(excluding:["cm0.steampowered.com:443"])
  assert(reset.endpoint=="cm1.steampowered.com:443")
  let unhealthyFailures=await unhealthy.failures();assert(unhealthyFailures==[3,0])
  do {_ = try await unhealthy.getServer(excluding:["cm0.steampowered.com:443","cm1.steampowered.com:443"]);fatalError("excluded endpoint reused")}
  catch {assert((error as? SteamError)==SteamError.noServersAvailable)}
  let list=CMServerList();await list.seed(3)
  let h=Harness(list,[-1200,-1003,nil]);try await h.connect()
  let status=await h.status();assert(status.0==3&&status.1==1&&status.2==2&&status.3==2)
  await h.staleDisconnect();await h.staleMessage()
  let afterStale=await h.status();assert(afterStale.1==1&&afterStale.2==2&&afterStale.3==2)
  let oldMessages=await h.delivered();assert(oldMessages.isEmpty)
  await h.currentMessage();let validMessages=await h.delivered();assert(validMessages==[Data([2])])
  let names=await h.attempts;assert(Set(names).count==3)
  let failed=await list.failures();assert(failed==[1,1,0])
  let trustList=CMServerList();await trustList.seed(3);let trust=Harness(trustList,[-1202,nil])
  do {try await trust.connect();fatalError("trust failure accepted")} catch {
   assert((error as? SteamError) == .transportFailed(domain:NSURLErrorDomain,code:-1202))
   assert(!error.localizedDescription.contains("secret-token"))
  }
  let ts=await trust.status();assert(ts.0==1&&ts.1==0&&ts.2==1&&ts.3==1)
  let singleList=CMServerList();await singleList.seed(1);let single=Harness(singleList,[-1200])
  do {try await single.connect();fatalError("same endpoint retried")} catch {
   assert((error as? SteamError) == .transportFailed(domain:NSURLErrorDomain,code:-1200))
  }
  let ss=await single.status();assert(ss.0==1&&ss.2==1)
  let cancelList=CMServerList();await cancelList.seed(3);let cancelled=Harness(cancelList,[-999,nil])
  do {try await cancelled.connect();fatalError("cancel ignored")} catch {assert(error is CancellationError)}
  let cs=await cancelled.status();assert(cs.0==1&&cs.1==0&&cs.2==1)
  let allList=CMServerList();await allList.seed(5);let all=Harness(allList,[-1200,-1200,-1200,nil])
  do {try await all.connect();fatalError("budget exceeded")} catch {
   assert((error as? SteamError) == .transportFailed(domain:NSURLErrorDomain,code:-1200))
  }
  let a=await all.status();assert(a.0==3&&a.2==3&&a.3==3)
  // Even a successful ping must not publish a connection after its caller cancels.
  let lateList=CMServerList();await lateList.seed(3);let late=Harness(lateList,[nil])
  await late.holdAttempt();let lateStart=Task{try await late.connect()}
  await late.waitUntilHeld();lateStart.cancel();await late.releaseAttempt()
  do {try await lateStart.value;fatalError("cancelled success accepted")} catch {assert(error is CancellationError)}
  let ls=await late.status();assert(ls.0==1&&ls.1==0&&ls.2==1&&ls.3==1)
  let lateFailures=await lateList.failures();assert(lateFailures==[0,0,0])
  // A replaced connect must neither cancel nor publish messages to the new one.
  let replaceList=CMServerList();await replaceList.seed(3);let replace=Harness(replaceList,[nil,nil])
  await replace.holdAttempt();let oldStart=Task{try await replace.connect()}
  await replace.waitUntilHeld();try await replace.connect();await replace.releaseAttempt()
  do {try await oldStart.value;fatalError("replaced connection accepted")} catch {assert(error is CancellationError)}
  await replace.staleMessage();await replace.staleDisconnect()
  let replaced=await replace.status();assert(replaced.0==2&&replaced.1==1&&replaced.2==1&&replaced.3==1)
  let replacementMessages=await replace.delivered();assert(replacementMessages.isEmpty)
  await replace.currentDisconnect();await replace.currentDisconnect()
  let disconnects=await replace.disconnected();assert(disconnects==1)
  let closed=await replace.status();assert(closed.2==2&&closed.3==2)
  let endpoint=await replace.currentEndpoint;assert(endpoint != nil)
  print("PASS: distinct CM selection, 3-attempt bound, cleanup, success marking, certificate fail-closed, cancellation including late success, redaction, replacement connections and stale-message isolation")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.swift').write_text(error+'\n'+servers+'\n'+h)
 subprocess.run([os.environ.get('SWIFTC','swiftc'),'-swift-version','5','-warnings-as-errors','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=30)
assert 'cont.resume(throwing: error)' in s
assert 'guard webSocketTask === task else { return }' in s
assert 'serverList.getServer(excluding: tried)' in s
assert 'didReceive challenge' not in s,'no TLS trust override may be added'
