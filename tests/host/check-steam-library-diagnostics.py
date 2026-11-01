#!/usr/bin/env python3
"""Execute the actual injected observer: argument/result/throw/promise contracts."""
from pathlib import Path
import subprocess,tempfile,os,re
root=Path(__file__).resolve().parents[2]
s=(root/'app/Madeira/SteamLibraryDiagnostics.swift').read_text()
js=s.split('static let observer = #"""',1)[1].split('"""#',1)[0]
code=r'''
const assert=require('assert'),vm=require('vm');
let events=[],interval,seenArgs,seenThis;const callbacks=[];
const sameError=new TypeError('private-sensitive-message');
const promise=Promise.reject(sameError);let unhandled=false;
process.on('unhandledRejection',value=>{if(value===sameError)unhandled=true;});
const apps={GetLibraryApps:function(...a){seenArgs=a;seenThis=this;return promise},GetAppOverview:function(id){return [{appid:730},{appid:440}]},GetAppError:function(){throw sameError},BIsAppInstalled:id=>id===730};
const lazy=[];Object.defineProperty(lazy,'0',{get(){throw sameError}});apps.GetAppLazy=()=>lazy;
const cb=()=>{},object={secret:'not logged'};
const context={SteamClient:{Apps:apps},__madeiraLibraryEvent:x=>events.push(JSON.parse(x)),addEventListener:(k,f)=>callbacks.push(k),setInterval:f=>{interval=f;return 1},clearInterval:()=>{},location:{pathname:'/library/home'},Promise,WeakRef};
vm.createContext(context);
'''+'vm.runInContext('+repr(js)+r''',context);
assert.strictEqual(apps.GetLibraryApps(730,cb,object),promise);assert.strictEqual(seenThis,apps);assert.strictEqual(seenArgs[1],cb);assert.strictEqual(seenArgs[2],object);
assert.strictEqual(context.__madeiraLibraryPromises.get(1).deref(),promise);
assert.deepStrictEqual(apps.GetAppOverview(730),[{appid:730},{appid:440}]);
try{apps.GetAppError()}catch(e){assert.strictEqual(e,sameError)}
assert.strictEqual(apps.BIsAppInstalled(730),true);assert(events.some(x=>x.event==='return'&&x.result.cs2===true));
assert.strictEqual(apps.GetAppLazy(),lazy,'diagnostic metadata failure must never replace a successful result');
const installed=apps.GetLibraryApps;interval();assert.strictEqual(apps.GetLibraryApps,installed);
for(let i=0;i<200;i++)apps.GetAppOverview(730);assert(events.length<=160);
assert(!JSON.stringify(events).includes('private-sensitive-message'));assert(!JSON.stringify(events).includes('secret'));assert(callbacks.includes('unhandledrejection'));
setImmediate(()=>{assert(unhandled,'observer must not add a rejection handler');console.log('PASS real observer preserves this, argument/callback/result/promise and error identities, leaves rejection unhandled, observes CS2 metadata and bounds output without payloads');});
'''
# Python repr is valid JS for this ASCII script; no shell interpolation.
with tempfile.TemporaryDirectory() as t:
 p=Path(t)/'check.js';p.write_text(code);subprocess.run(['node',str(p)],check=True)
assert 'Runtime.awaitPromise' not in s and '.then(' not in js
assert '127.0.0.1' in s and 'endpoint.port == port' in s
# Compile real privacy methods on macOS as well as the production actor.
if os.uname().sysname=='Darwin':
 with tempfile.TemporaryDirectory() as t:
  d=Path(t);stub=d/'stubs.swift';stub.write_text('import Foundation\n@MainActor final class LogStore { static let shared=LogStore();func log(_ s:String){} }\nenum MadeiraConfig { static func flag(_ s:String)->Bool{false} }\n')
  subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-emit-module',str(stub),str(root/'app/Madeira/SteamLibraryDiagnostics.swift'),'-o',str(d/'Observer.swiftmodule')],check=True)
  main=d/'main.swift';main.write_text("import Foundation\n@main struct Check { @MainActor static func main(){ let url=SteamLibraryDiagnostics.safeURL(\"https://name:password@steamloopback.host/library/home?token=SECRET#cookie\");assert(!url.contains(\"SECRET\") && !url.contains(\"password\") && !url.contains(\"cookie\"));let event=SteamLibraryDiagnostics.safeEvent([\"event\":\"return\",\"method\":\"GetLibraryApps\",\"token\":\"SECRET\",\"result\":[\"type\":\"array\",\"count\":2,\"cs2\":true,\"body\":\"SECRET\"]]);assert(!event.contains(\"SECRET\") && event.contains(\"cs2\"));print(\"PASS real Swift diagnostic privacy filters\") } }\n")
  exe=d/'privacy';subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(stub),str(root/'app/Madeira/SteamLibraryDiagnostics.swift'),str(main),'-o',str(exe)],check=True);subprocess.run([str(exe)],check=True)
print('PASS observer source scope: loopback endpoint validation, no request/certificate interception or Promise handlers')
