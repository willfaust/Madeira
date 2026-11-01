#!/usr/bin/env python3
"""Exercise passive CEF events, real flag semantics and side-effect-free snapshots."""
from pathlib import Path
import subprocess, tempfile, os
root = Path(__file__).resolve().parents[2]
s = (root/'app/Madeira/SteamLibraryDiagnostics.swift').read_text()
expression = s.split('static let snapshotExpression = #"""', 1)[1].split('"""#', 1)[0]
assert 'fallback: false' in s and 'MadeiraConfig.flag("MADEIRA_STEAM_LIBRARY_TRACE_OFF", fallback: false)' in s
for forbidden in ['Runtime.addBinding', 'Page.addScriptToEvaluateOnNewDocument', 'Runtime.callFunctionOn', 'Runtime.getProperties', 'Runtime.awaitPromise', 'addEventListener(', 'Object.defineProperty(', 'Reflect.apply(', 'setInterval(', '.then(']:
    assert forbidden not in s, forbidden
assert '"throwOnSideEffect": true' in s and 'endpoint.port == port' in s
code = r'''
const vm=require('vm'),assert=require('assert');let nativeCalls=0;
const original=function(){nativeCalls++;return Promise.resolve('private')};
const apps=Object.freeze({GetAppOverview:original});
const store=Object.freeze({m_bIsInitialized:true,m_mapApps:new Map([[730,{appid:730}]])});
const context={SteamClient:Object.freeze({Apps:apps}),appStore:store};vm.createContext(context);
const keys=Object.keys(context);const result=vm.runInContext(EXPRESSION,context);
assert(result.store&&result.ready&&result.cs2&&result.apps&&result.count===1);
assert.strictEqual(context.SteamClient.Apps.GetAppOverview,original);assert.strictEqual(nativeCalls,0);
assert.deepStrictEqual(Object.keys(context),keys);assert.strictEqual(store.m_mapApps.size,1);
console.log('PASS actual read-only snapshot leaves globals/functions unchanged and issues no SteamClient API calls');
'''.replace('EXPRESSION',repr(expression))
with tempfile.TemporaryDirectory() as t:
    p=Path(t)/'check.js';p.write_text(code);subprocess.run(['node',str(p)],check=True)
# Extract the production implementation, retaining its fallback:true default.
config=(root/'app/Madeira/MadeiraConfig.swift').read_text()
a=config.index('    static func flag(');i=config.index('{',a)+1;depth=1
while depth: depth+=(config[i]=='{')-(config[i]=='}');i+=1
flag=config[a:i]
assert 'fallback: Bool = true' in flag
if os.uname().sysname=='Darwin':
    with tempfile.TemporaryDirectory() as t:
        d=Path(t);stub=d/'stubs.swift'
        stub.write_text('''import Foundation
@MainActor final class LogStore {static let shared=LogStore();var lines:[String]=[];func log(_ s:String){lines.append(s)}}
enum MadeiraConfig {static var presentCached=false;static var values:[String:String]=[:];static func all()->[String:String]{values}
'''+flag+'''
}
struct DockGame {var id:Int;var installed:Bool;var library:String;var installDir:String}
enum MadeiraDock {static let drive=URL(fileURLWithPath:"/tmp");static func games(drive:URL)->[DockGame]{[]}}
enum NativeSteamPlay {static func libraryListed(_ g:DockGame,root:String,drive:URL)->Bool{false}}
''')
        probe=d/'probe.swift';probe.write_text(s+r'''
extension SteamLibraryDiagnostics {
 func runCDPFixture(_ endpoint:URL) async {
  await connect("fixture",endpoint:endpoint,pageURL:"https://steamloopback.host/library/home")
  stop()
 }
}
''')
        main=d/'main.swift';main.write_text(r'''import Foundation
@main struct Check {
 @MainActor static func main() async {
  let observer=SteamLibraryDiagnostics.shared
  unsetenv("MADEIRA_STEAM_LIBRARY_TRACE_OFF")
  assert(MadeiraConfig.flag("UNSET_PRODUCTION_FLAG"))
  observer.start();assert(getenv("MADEIRA_STEAM_CDP_PORT") != nil);observer.stop()
  setenv("MADEIRA_STEAM_LIBRARY_TRACE_OFF","1",1)
  observer.start();assert(getenv("MADEIRA_STEAM_CDP_PORT")==nil)
  assert(LogStore.shared.lines.contains(where:{$0.contains("observer=disabled")}))
  MadeiraConfig.presentCached=true;MadeiraConfig.values=["env.MADEIRA_STEAM_LIBRARY_TRACE_OFF":"0"]
  observer.start();assert(getenv("MADEIRA_STEAM_CDP_PORT") != nil);observer.stop()
  MadeiraConfig.values=["env.MADEIRA_STEAM_LIBRARY_TRACE_OFF":"1"]
  observer.start();assert(getenv("MADEIRA_STEAM_CDP_PORT")==nil)
  unsetenv("MADEIRA_STEAM_LIBRARY_TRACE_OFF");MadeiraConfig.presentCached=false
  print("PASS production flag fallback and config/env precedence: observer on by default, explicit off only")
  assert(SteamLibraryDiagnostics.safeURL("https://user:pass@steamloopback.host/library/home?token=SECRET#SECRET")=="https://steamloopback.host/library/home")
  assert(SteamLibraryDiagnostics.errorClass("TypeError: Cannot read properties of undefined (reading 'get') SECRET").contains("undefined-property=get"))
  await observer.runCDPFixture(URL(string:CommandLine.arguments[1])!)
  let lines=LogStore.shared.lines.joined(separator:"\n")
  for marker in ["navigation library=true","resource status=503","net::ERR_CONNECTION_REFUSED","console-frame function=AppStore.Init","Uncaught (in promise)","websocket handshake-status=101","websocket transport-error","readonly-store","\"cs2\":true"] {assert(lines.contains(marker),marker)}
  assert(LogStore.shared.lines.filter{$0.contains("console kind=warning")}.count==30)
  assert(LogStore.shared.lines.count<=300)
  assert(!lines.contains("SECRET") && !lines.contains("cookie=") && !lines.contains("authorization="))
  assert(!lines.contains("command-failed") && !lines.contains("command-timeout"))
  print("PASS actual passive Swift event processing: Library route, resource/status, console/exception stacks, WS transport and read-only state; secrets excluded")
 }
}
''')
        exe=d/'passive';subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(stub),str(probe),str(main),'-o',str(exe)],check=True)
        server=subprocess.Popen(['node',str(root/'tests/host/steam-library-cdp-fixture.js')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            port=int(server.stdout.readline().strip())
            subprocess.run([str(exe),'ws://127.0.0.1:'+str(port)],check=True,timeout=15)
            out=server.communicate(timeout=10)[0];print(out,end='');assert server.returncode==0 and 'PASS passive CDP' in out
        finally:
            if server.poll() is None:server.kill();server.wait()
print('PASS observer scope: passive protocol events and checked read-only state; no injected scripts, hooks, native API wrappers or Promise handlers')
