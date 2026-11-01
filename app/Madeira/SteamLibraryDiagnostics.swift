// SPDX-License-Identifier: GPL-3.0-or-later
// Local CEF developer-protocol observer. Never logs headers, cookies or bodies.
import Foundation
import Darwin

@MainActor final class SteamLibraryDiagnostics {
    static let shared = SteamLibraryDiagnostics()
    private var poll: Task<Void, Never>?
    private var sockets: [String: URLSessionWebSocketTask] = [:]
    private var sequence = 0
    private var emitted = 0
    private var categories: [String: Int] = [:]
    private var events = 0
    private var port = 0
    private var generation = 0
    private var requests: [String: (String, Date)] = [:]
    private var replies: [Int: ([String: Any]) -> Void] = [:]
    private var commands: [Int: String] = [:]
    private var discoveries = 0
    private var promises = 0
    private let session = URLSession(configuration: .ephemeral)

    static func safeURL(_ text: String) -> String {
        guard let u = URLComponents(string: text), let scheme = u.scheme,
              ["http", "https", "ws", "wss"].contains(scheme), let host = u.host else { return "[non-network-url]" }
        var c = URLComponents(); c.scheme = scheme; c.host = host; c.port = u.port
        c.path = u.path.replacingOccurrences(of: "[0-9]{12,}", with: "[id]", options: .regularExpression)
        return String((c.string ?? "[url]").prefix(240))
    }
    private func note(_ text: String, category: String = "navigation") {
        let limit = ["navigation": 20, "promise": 40, "js": 100, "network": 50, "failure": 70, "websocket": 20][category] ?? 0
        guard emitted < 300, categories[category, default: 0] < limit else { return }
        emitted += 1; categories[category, default: 0] += 1
        LogStore.shared.log("[steam-library-v1] \(text)")
    }
    func start() {
        stop(); emitted = 0; events = 0; discoveries = 0; categories.removeAll()
        guard !MadeiraConfig.flag("MADEIRA_STEAM_LIBRARY_TRACE_OFF") else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        close(fd); guard ok else { return }
        port = Int(UInt16(bigEndian: a.sin_port)); guard port >= 1024 else { return }
        setenv("MADEIRA_STEAM_CDP_PORT", String(port), 1)
        note("observer=loopback enabled; requests log URL without query; bodies and credentials excluded")
        let drive = MadeiraDock.drive
        if let game = MadeiraDock.games(drive: drive).first(where: { $0.id == 730 }) {
            let roots = ["Program Files (x86)/Steam", "Program Files/Steam"]
            let root = roots.first { FileManager.default.fileExists(atPath: drive.appendingPathComponent($0 + "/steam.exe").path) }
            let listed = root.map { NativeSteamPlay.libraryListed(game, root: $0, drive: drive) } ?? false
            let image = drive.appendingPathComponent(game.library + "/common/" + game.installDir + "/game/bin/win64/cs2.exe")
            note("local-install app=730 manifest-ready=\(game.installed) client-library-listed=\(listed) executable-present=\(FileManager.default.fileExists(atPath: image.path))")
        } else { note("local-install app=730 discovered=false") }
        let current = generation
        poll = Task { [weak self] in
            let end = Date().addingTimeInterval(600)
            while !Task.isCancelled && Date() < end {
                guard let self, self.generation == current else { return }
                await self.discover()
                let delay: UInt64 = self.sockets.isEmpty ? 500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
            if self?.generation == current { self?.stop() }
        }
    }
    func stop() {
        generation += 1
        poll?.cancel(); poll = nil
        for socket in sockets.values { socket.cancel(with: .goingAway, reason: nil) }
        sockets.removeAll(); requests.removeAll(); replies.removeAll(); commands.removeAll(); promises = 0; port = 0; unsetenv("MADEIRA_STEAM_CDP_PORT")
    }
    private func discover() async {
        expireRequests()
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return }
        discoveries += 1
        var request = URLRequest(url: url); request.timeoutInterval = 1
        guard let (data, _) = try? await session.data(for: request), data.count < 128_000,
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !Task.isCancelled, port > 0 else {
            if [20, 60, 240].contains(discoveries) { note("CEF endpoint unavailable poll=\(discoveries)", category: "failure") }
            return
        }
        for target in targets where sockets.count < 4 {
            guard target["type"] as? String == "page", let id = target["id"] as? String, sockets[id] == nil,
                  let address = target["webSocketDebuggerUrl"] as? String, let endpoint = URL(string: address),
                  ["127.0.0.1", "localhost"].contains(endpoint.host ?? ""), endpoint.port == port else { continue }
            let socket = session.webSocketTask(with: endpoint); socket.maximumMessageSize = 2_000_000
            sockets[id] = socket; socket.resume()
            note("page-attached url=\(Self.safeURL(target["url"] as? String ?? ""))")
            await send(socket, "Runtime.enable"); await send(socket, "Page.enable")
            await send(socket, "Network.enable", ["maxPostDataSize": 0, "maxTotalBufferSize": 1_048_576, "maxResourceBufferSize": 16_384])
            await send(socket, "Runtime.addBinding", ["name": "__madeiraLibraryEvent"])
            await send(socket, "Page.addScriptToEvaluateOnNewDocument", ["source": Self.observer])
            await send(socket, "Runtime.evaluate", ["expression": Self.observer])
            Task { [weak self] in
                while !Task.isCancelled {
                    guard let message = try? await socket.receive() else { break }
                    if case .string(let text) = message { await self?.receive(text, socket: socket) }
                }
                if self?.sockets[id] === socket { self?.sockets.removeValue(forKey: id) }
            }
        }
    }
    private func send(_ socket: URLSessionWebSocketTask, _ method: String, _ params: [String: Any] = [:], reply: (([String: Any]) -> Void)? = nil) async {
        sequence += 1
        if commands.count < 128 { commands[sequence] = method }
        if let reply, replies.count < 64 { replies[sequence] = reply }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": sequence, "method": method, "params": params]),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await socket.send(.string(text))
    }
    private func receive(_ text: String, socket: URLSessionWebSocketTask) async {
        events += 1
        guard events <= 8000, let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = event["id"] as? Int {
            let command = commands.removeValue(forKey: id) ?? "unknown"
            if let error = event["error"] as? [String: Any] { note("CEF command-failed method=\(command) code=\(error["code"] as? Int ?? 0)", category: "failure") }
            if let callback = replies.removeValue(forKey: id) { callback(event["result"] as? [String: Any] ?? [:]) }
            return
        }
        let method = event["method"] as? String ?? ""
        let p = event["params"] as? [String: Any] ?? [:]
        if ["Page.frameNavigated", "Page.navigatedWithinDocument"].contains(method) {
            let url = (p["frame"] as? [String: Any])?["url"] as? String ?? p["url"] as? String ?? ""
            note("navigation library=\(url.contains("/library")) url=\(Self.safeURL(url))")
        } else if method == "Runtime.executionContextCreated", let ctx = p["context"] as? [String: Any], let id = ctx["id"] {
            await send(socket, "Runtime.evaluate", ["expression": Self.observer, "contextId": id])
        } else if method == "Runtime.bindingCalled", p["name"] as? String == "__madeiraLibraryEvent",
                  let payload = p["payload"] as? String, payload.count < 2000 {
            if let data = payload.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                note("js context=\(p["executionContextId"] as? Int ?? 0) \(Self.safeEvent(value))", category: ["throw", "error", "unhandled-rejection", "unavailable"].contains(value["event"] as? String ?? "") ? "failure" : "js")
                if value["inspect"] as? Bool == true, let id = value["id"] as? Int, promises < 24 {
                    promises += 1; inspectPromise(id, context: p["executionContextId"] as? Int, socket: socket)
                }
            }
        } else if method == "Runtime.exceptionThrown", let detail = p["exceptionDetails"] as? [String: Any] {
            let frames = (detail["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]] ?? []
            for frame in frames.prefix(6) {
                note("exception-frame url=\(Self.safeURL(frame["url"] as? String ?? "")) line=\(frame["lineNumber"] ?? 0) column=\(frame["columnNumber"] ?? 0)", category: "failure")
            }
        } else if method == "Runtime.consoleAPICalled", ["error", "warning"].contains(p["type"] as? String ?? "") {
            let args = p["args"] as? [[String: Any]] ?? []
            let known = ["TypeError", "Remote call failed", "Failed to load", "Unhandled"]
            let classes = known.filter { term in args.contains { (($0["value"] as? String) ?? ($0["description"] as? String) ?? "").contains(term) } }
            note("console kind=\(p["type"] as? String ?? "error") classes=\(classes.joined(separator: ","))", category: "failure")
            for f in ((p["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]] ?? []).prefix(6) {
                note("console-frame url=\(Self.safeURL(f["url"] as? String ?? "")) line=\(f["lineNumber"] ?? 0) column=\(f["columnNumber"] ?? 0)", category: "failure")
            }
        } else if method == "Network.requestWillBeSent", let id = p["requestId"] as? String,
                  let request = p["request"] as? [String: Any], requests.count < 512 {
            requests[id] = (Self.safeURL(request["url"] as? String ?? ""), Date())
        } else if method == "Network.responseReceived", let response = p["response"] as? [String: Any] {
            let status = response["status"] as? Int ?? 0
            let url = Self.safeURL(response["url"] as? String ?? "")
            if status >= 400 || url.contains("library") || url.contains("chunk~") { note("resource status=\(status) url=\(url)", category: status >= 400 ? "failure" : "network") }
        } else if method == "Network.loadingFailed", let id = p["requestId"] as? String {
            let error = p["errorText"] as? String ?? ""
            let code = error.range(of: "^net::ERR_[A-Z0-9_]+$", options: .regularExpression) != nil ? error : "unknown"
            note("resource-failed url=\(requests[id]?.0 ?? "[unknown]") code=\(code) canceled=\(p["canceled"] as? Bool ?? false)", category: "failure")
            requests.removeValue(forKey: id)
        } else if method == "Network.loadingFinished", let id = p["requestId"] as? String { requests.removeValue(forKey: id)
        } else if method == "Network.webSocketCreated" {
            note("websocket url=\(Self.safeURL(p["url"] as? String ?? ""))", category: "websocket")
        } else if method == "Network.webSocketFrameError" { note("websocket transport-error", category: "failure")
        } else if ["Network.webSocketFrameSent", "Network.webSocketFrameReceived"].contains(method), let frame = p["response"] as? [String: Any], let payload = frame["payloadData"] as? String {
            note("websocket direction=\(method.hasSuffix("Sent") ? "send" : "receive") bytes=\(payload.utf8.count) opcode=\(frame["opcode"] ?? 0)", category: "websocket")
        }
        expireRequests()
    }
    private func expireRequests() {
        for (id, value) in requests where Date().timeIntervalSince(value.1) > 30 {
            note("resource-timeout url=\(value.0)", category: "failure"); requests.removeValue(forKey: id)
        }
    }

    static func safeEvent(_ value: [String: Any]) -> String {
        var clean: [String: Any] = [:]
        let enums = ["event": ["binding", "call", "return", "throw", "unavailable", "installed", "store", "error", "unhandled-rejection"], "name": ["Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "EvalError", "URIError"], "path": ["library", "other"], "namespace": ["Apps", "Storage", "CloudStorage"]]
        for (key, allowed) in enums { if let value = value[key] as? String, allowed.contains(value) { clean[key] = value } }
        if let method = value["method"] as? String, method.count < 100, method.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil { clean["method"] = method }
        for k in ["id", "argc", "line", "column"] { if let v = value[k] as? Int, v >= 0, v < 1_000_000 { clean[k] = v } }
        for k in ["cs2", "apps", "promise", "inspect", "ready"] { if let v = value[k] as? Bool { clean[k] = v } }
        func meta(_ source: [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            if let type = source["type"] as? String, ["null", "array", "object", "number", "string", "function", "boolean", "undefined", "bigint"].contains(type) { out["type"] = type }
            if let count = source["count"] as? Int, count >= 0, count <= 1_000_000 { out["count"] = count }
            if let cs2 = source["cs2"] as? Bool { out["cs2"] = cs2 }
            if let code = source["code"] as? Int, code >= -2147483648, code <= 2147483647 { out["code"] = code }
            if let failed = source["remoteFailed"] as? Bool { out["remoteFailed"] = failed }; return out
        }
        if let r = value["result"] as? [String: Any] { clean["result"] = meta(r) }
        if let r = value["result"] as? [[String: Any]] { clean["result"] = r.prefix(8).map(meta) }
        let data = (try? JSONSerialization.data(withJSONObject: clean, options: .sortedKeys)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    private func inspectPromise(_ id: Int, context: Int?, socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            var settled = false
            for attempt in 0..<6 {
                guard let self else { return }
                if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                if settled { break }
                guard self.sockets.values.contains(where: { $0 === socket }) else { return }
                var evaluation: [String: Any] = ["expression": "globalThis.__madeiraLibraryPromises?.get(\(id))?.deref()", "objectGroup": "madeira-library-\(context ?? 0)-\(id)"]
                if let context { evaluation["contextId"] = context }
                await self.send(socket, "Runtime.evaluate", evaluation) { [weak self] r in
                    guard let object = (r["result"] as? [String: Any])?["objectId"] as? String else { return }
                    Task { [weak self] in
                        await self?.send(socket, "Runtime.getProperties", ["objectId": object, "ownProperties": true]) { [weak self] result in
                            let internals = result["internalProperties"] as? [[String: Any]] ?? []
                            let state = (internals.first { $0["name"] as? String == "[[PromiseState]]" }?["value"] as? [String: Any])?["value"] as? String ?? "unknown"
                            guard ["pending", "fulfilled", "rejected"].contains(state) else { return }
                            settled = state != "pending"
                            self?.note("promise context=\(context ?? 0) id=\(id) state=\(state) sample=\(attempt)", category: state == "rejected" ? "failure" : "promise")
                            if state == "pending" && attempt == 5 { self?.note("promise-timeout context=\(context ?? 0) id=\(id) elapsed=25s", category: "failure") }
                            if let value = internals.first(where: { $0["name"] as? String == "[[PromiseResult]]" })?["value"] as? [String: Any], let resultID = value["objectId"] as? String, state != "pending" {
                                Task { [weak self] in
                                    await self?.send(socket, "Runtime.callFunctionOn", ["objectId": resultID, "functionDeclaration": "function(){const d=k=>Object.getOwnPropertyDescriptor(this,k)?.value;const c=d('eresult')??d('code')??d('result');return {type:Array.isArray(this)?'array':'object',...((()=>{if(!Array.isArray(this))return {};let found=false;for(let i=0;i<Math.min(this.length,4096);i++){const x=d(String(i));if(x===730||Object.getOwnPropertyDescriptor(x||{},'appid')?.value===730){found=true;break}}return {count:this.length,...(found||this.length<=4096?{cs2:found}:{})}})()),code:Number.isInteger(c)?c:undefined,remoteFailed:typeof d('message')==='string'&&d('message').includes('Remote call failed')}}", "returnByValue": true]) { [weak self] r in
                                        if let summary = (r["result"] as? [String: Any])?["value"] as? [String: Any] { self?.note("promise-data id=\(id) \(Self.safeEvent(["result":summary]))", category: summary["remoteFailed"] as? Bool == true ? "failure" : "promise") }
                                    }
                                }
                            } else if state != "pending", let value = internals.first(where: { $0["name"] as? String == "[[PromiseResult]]" })?["value"] as? [String: Any] {
                                let raw = value["value"] as? String
                                var summary: [String: Any] = ["type": value["type"] as? String ?? "undefined", "remoteFailed": raw?.contains("Remote call failed") ?? false]
                                if let raw { summary["count"] = raw.count }
                                if let number = value["value"] as? Int { summary["code"] = number }
                                self?.note("promise-data id=\(id) \(Self.safeEvent(["result": summary]))", category: state == "rejected" ? "failure" : "promise")
                            }
                        }
                    }
                }
            }
            await self?.send(socket, "Runtime.releaseObjectGroup", ["objectGroup": "madeira-library-\(context ?? 0)-\(id)"])
        }
    }

    // Contract: original functions/callback arguments/this/results/errors pass through.
    // Promises are not given handlers: this preserves unhandled-rejection semantics.
    static let observer = #"""
    (()=>{if(globalThis.__madeiraLibraryObserver)return;Object.defineProperty(globalThis,'__madeiraLibraryObserver',{value:true});
    let budget=128,reserved=32, serial=0,lastApps,lastStore;const watched=new WeakSet(),perMethod=new Map(),perNamespace=new Map();Object.defineProperty(globalThis,'__madeiraLibraryPromises',{value:new Map()});
    const emit=x=>{const critical=['store','error','unhandled-rejection','throw'].includes(x.event);if((critical?reserved--:budget--)>0)try{globalThis.__madeiraLibraryEvent(JSON.stringify(x))}catch(_){}};
    const summary=x=>{if(x===null)return {type:'null'};if(Array.isArray(x)){let found=false;for(let i=0;i<Math.min(x.length,4096);i++){const a=Object.getOwnPropertyDescriptor(x,String(i))?.value;if(a===730||(a&&typeof a==='object'&&Object.getOwnPropertyDescriptor(a,'appid')?.value===730)){found=true;break}}return {type:'array',count:x.length,...(found||x.length<=4096?{cs2:found}:{})}};return {type:typeof x,...(typeof x==='string'?{count:x.length}:{})}};
    addEventListener('error',e=>emit({event:'error',name:e.error?.name||'Error',line:e.lineno,column:e.colno}));
    addEventListener('unhandledrejection',e=>emit({event:'unhandled-rejection',name:e.reason?.name||typeof e.reason}));
    const wrap=(apps,namespace)=>{if(!apps)return;for(const key of Object.getOwnPropertyNames(apps)){
      if(!(namespace==='Apps'?/^(Get.*(App|Game|Library)|(UnregisterFor|RegisterFor).*(App|Game|Library)|BIs.*(Installed|Subscribed|Owned))/:/^(Get|Read|RegisterFor|UnregisterFor)/).test(key))continue;
      const d=Object.getOwnPropertyDescriptor(apps,key);if(!d||typeof d.value!=='function'||watched.has(d.value))continue;
      const fn=d.value;watched.add(fn);const methodKey=namespace+'.'+key;const wrapped=function(...args){if(budget<=0||(perMethod.get(methodKey)||0)>=8)return Reflect.apply(fn,this,args);perMethod.set(methodKey,(perMethod.get(methodKey)||0)+1);const id=++serial;emit({event:'call',namespace,method:key,id,argc:args.length,cs2:args.includes(730)});
        let result;try{result=Reflect.apply(fn,this,args)}catch(e){emit({event:'throw',namespace,method:key,id,name:'Error'});throw e}
        try{const promise=result instanceof Promise;const tracked=promise&&globalThis.__madeiraLibraryPromises.size<24&&(perNamespace.get(namespace)||0)<8;if(tracked){globalThis.__madeiraLibraryPromises.set(id,new WeakRef(result));perNamespace.set(namespace,(perNamespace.get(namespace)||0)+1)}const meta=summary(result);if(args[0]===730&&typeof result==='boolean'&&/^BIs/.test(key))meta.cs2=result;emit({event:'return',namespace,method:key,id,promise,inspect:tracked,result:meta})}catch(_){emit({event:'unavailable',namespace,method:key,id})}return result};
      try{Object.defineProperty(wrapped,'name',{value:fn.name});Object.defineProperty(wrapped,'length',{value:fn.length});
        Object.defineProperty(apps,key,{...d,value:wrapped});watched.add(wrapped)}catch(_){emit({event:'unavailable',namespace,method:key})}
    }};
    const setup=()=>{const client=globalThis.SteamClient,apps=client?.Apps;if(!!apps!==lastApps){emit({event:'binding',apps:!!apps});if(apps)for(const m of ['GetAppOverview','GetAppDetails','RegisterForAppOverviewChanges'])emit({event:'binding',method:m,apps:typeof Object.getOwnPropertyDescriptor(apps,m)?.value==='function'})}lastApps=!!apps;for(const n of ['Apps','Storage','CloudStorage'])wrap(client?.[n],n)};
    const snapshot=()=>{const s=globalThis.appStore,m=s?.m_mapApps;const count=m&&Number.isInteger(m.size)?m.size:undefined;const state={event:'store',apps:!!s,ready:typeof s?.m_bIsInitialized==='boolean'?s.m_bIsInitialized:undefined,result:{type:'object',count,cs2:m&&typeof m.has==='function'?m.has(730):undefined}};const key=JSON.stringify(state);if(key!==lastStore){lastStore=key;emit(state)}};
    const run=()=>{try{setup();snapshot()}catch(_){emit({event:'unavailable',method:'setup'})}};run();let attempts=0;const timer=setInterval(()=>{run();if(++attempts>=300)clearInterval(timer)},1000);
    emit({event:'installed',path:location.pathname.startsWith('/library')?'library':'other'});
    })()
    """#
}
