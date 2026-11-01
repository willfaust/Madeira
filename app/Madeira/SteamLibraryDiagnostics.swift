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
    private var events = 0
    private var port = 0
    private var generation = 0
    private var requests: [String: (String, Date)] = [:]
    private var replies: [Int: ([String: Any]) -> Void] = [:]
    private var promises = 0
    private let session = URLSession(configuration: .ephemeral)

    static func safeURL(_ text: String) -> String {
        guard let u = URLComponents(string: text), let scheme = u.scheme,
              ["http", "https", "ws", "wss"].contains(scheme), let host = u.host else { return "[non-network-url]" }
        var c = URLComponents(); c.scheme = scheme; c.host = host; c.port = u.port
        c.path = u.path.replacingOccurrences(of: "[0-9]{12,}", with: "[id]", options: .regularExpression)
        return String((c.string ?? "[url]").prefix(240))
    }
    private func note(_ text: String) {
        guard emitted < 300 else { return }; emitted += 1
        LogStore.shared.log("[steam-library-v1] \(text)")
    }
    func start() {
        stop(); emitted = 0; events = 0
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
        let current = generation
        poll = Task { [weak self] in
            let end = Date().addingTimeInterval(600)
            while !Task.isCancelled && Date() < end {
                guard let self, self.generation == current else { return }
                await self.discover()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if self?.generation == current { self?.stop() }
        }
    }
    func stop() {
        generation += 1
        poll?.cancel(); poll = nil
        for socket in sockets.values { socket.cancel(with: .goingAway, reason: nil) }
        sockets.removeAll(); requests.removeAll(); replies.removeAll(); promises = 0; port = 0; unsetenv("MADEIRA_STEAM_CDP_PORT")
    }
    private func discover() async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return }
        var request = URLRequest(url: url); request.timeoutInterval = 1
        guard let (data, _) = try? await session.data(for: request), data.count < 128_000,
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !Task.isCancelled, port > 0 else { return }
        for target in targets where sockets.count < 4 {
            guard target["type"] as? String == "page", let id = target["id"] as? String, sockets[id] == nil,
                  let address = target["webSocketDebuggerUrl"] as? String, let endpoint = URL(string: address),
                  ["127.0.0.1", "localhost"].contains(endpoint.host ?? ""), endpoint.port == port else { continue }
            let socket = session.webSocketTask(with: endpoint); socket.maximumMessageSize = 2_000_000
            sockets[id] = socket; socket.resume()
            note("page-attached url=\(Self.safeURL(target["url"] as? String ?? ""))")
            await send(socket, "Runtime.enable"); await send(socket, "Page.enable")
            await send(socket, "Network.enable", ["maxPostDataSize": 0])
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
        if let reply, replies.count < 64 { replies[sequence] = reply }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": sequence, "method": method, "params": params]),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await socket.send(.string(text))
    }
    private func receive(_ text: String, socket: URLSessionWebSocketTask) async {
        events += 1
        guard events <= 8000, let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = event["id"] as? Int, let callback = replies.removeValue(forKey: id) { callback(event["result"] as? [String: Any] ?? [:]); return }
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
                note("js=\(Self.safeEvent(value))")
                if value["promise"] as? Bool == true, let id = value["id"] as? Int, promises < 24 {
                    promises += 1; inspectPromise(id, context: p["executionContextId"] as? Int, socket: socket)
                }
            }
        } else if method == "Runtime.exceptionThrown", let detail = p["exceptionDetails"] as? [String: Any] {
            let frames = (detail["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]] ?? []
            for frame in frames.prefix(6) {
                note("exception-frame url=\(Self.safeURL(frame["url"] as? String ?? "")) line=\(frame["lineNumber"] ?? 0) column=\(frame["columnNumber"] ?? 0)")
            }
        } else if method == "Runtime.consoleAPICalled", ["error", "warning"].contains(p["type"] as? String ?? "") {
            let args = p["args"] as? [[String: Any]] ?? []
            let known = ["TypeError", "Remote call failed", "Failed to load", "Unhandled"]
            let classes = known.filter { term in args.contains { (($0["value"] as? String) ?? ($0["description"] as? String) ?? "").contains(term) } }
            note("console kind=\(p["type"] as? String ?? "error") classes=\(classes.joined(separator: ","))")
            for f in ((p["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]] ?? []).prefix(6) {
                note("console-frame url=\(Self.safeURL(f["url"] as? String ?? "")) line=\(f["lineNumber"] ?? 0) column=\(f["columnNumber"] ?? 0)")
            }
        } else if method == "Network.requestWillBeSent", let id = p["requestId"] as? String,
                  let request = p["request"] as? [String: Any], requests.count < 512 {
            requests[id] = (Self.safeURL(request["url"] as? String ?? ""), Date())
        } else if method == "Network.responseReceived", let response = p["response"] as? [String: Any] {
            let status = response["status"] as? Int ?? 0
            let url = Self.safeURL(response["url"] as? String ?? "")
            if status >= 400 || url.contains("library") || url.contains("chunk~") { note("resource status=\(status) url=\(url)") }
        } else if method == "Network.loadingFailed", let id = p["requestId"] as? String {
            let error = p["errorText"] as? String ?? ""
            let code = error.range(of: "^net::ERR_[A-Z0-9_]+$", options: .regularExpression) != nil ? error : "unknown"
            note("resource-failed url=\(requests[id]?.0 ?? "[unknown]") code=\(code) canceled=\(p["canceled"] as? Bool ?? false)")
            requests.removeValue(forKey: id)
        } else if method == "Network.loadingFinished", let id = p["requestId"] as? String { requests.removeValue(forKey: id)
        } else if method == "Network.webSocketCreated" {
            note("websocket url=\(Self.safeURL(p["url"] as? String ?? ""))")
        } else if method == "Network.webSocketFrameError" { note("websocket transport-error")
        } else if ["Network.webSocketFrameSent", "Network.webSocketFrameReceived"].contains(method), let frame = p["response"] as? [String: Any], let payload = frame["payloadData"] as? String {
            note("websocket direction=\(method.hasSuffix("Sent") ? "send" : "receive") bytes=\(payload.utf8.count) opcode=\(frame["opcode"] ?? 0)")
        }
        for (id, value) in requests where Date().timeIntervalSince(value.1) > 30 {
            note("resource-timeout url=\(value.0)"); requests.removeValue(forKey: id)
        }
    }

    static func safeEvent(_ value: [String: Any]) -> String {
        var clean: [String: Any] = [:]
        let enums = ["event": ["binding", "call", "return", "throw", "unavailable", "installed", "error", "unhandled-rejection"], "name": ["Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "EvalError", "URIError"], "path": ["library", "other"]]
        for (key, allowed) in enums { if let value = value[key] as? String, allowed.contains(value) { clean[key] = value } }
        if let method = value["method"] as? String, method.count < 100, method.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil { clean["method"] = method }
        for k in ["id", "argc"] { if let v = value[k] as? Int, v >= 0, v < 1_000_000 { clean[k] = v } }
        for k in ["cs2", "apps", "promise"] { if let v = value[k] as? Bool { clean[k] = v } }
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
            for attempt in 0..<6 {
                guard let self else { return }
                if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
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
                            self?.note("promise context=\(context ?? 0) id=\(id) state=\(state) sample=\(attempt)")
                            if state == "pending" && attempt == 5 { self?.note("promise-timeout context=\(context ?? 0) id=\(id) elapsed=25s") }
                            if let value = internals.first(where: { $0["name"] as? String == "[[PromiseResult]]" })?["value"] as? [String: Any], let resultID = value["objectId"] as? String, state != "pending" {
                                Task { [weak self] in
                                    await self?.send(socket, "Runtime.callFunctionOn", ["objectId": resultID, "functionDeclaration": "function(){const d=k=>Object.getOwnPropertyDescriptor(this,k)?.value;const c=d('eresult')??d('code')??d('result');return {type:Array.isArray(this)?'array':'object',count:Array.isArray(this)?this.length:0,cs2:Array.isArray(this)&&this.some(x=>x===730||Object.getOwnPropertyDescriptor(x||{},'appid')?.value===730),code:Number.isInteger(c)?c:undefined,remoteFailed:typeof d('message')==='string'&&d('message').includes('Remote call failed')}}", "returnByValue": true]) { [weak self] r in
                                        if let summary = (r["result"] as? [String: Any])?["value"] as? [String: Any] { self?.note("promise-data id=\(id) \(Self.safeEvent(["result":summary]))") }
                                    }
                                }
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
    let budget=160, serial=0,lastApps;const watched=new WeakSet();Object.defineProperty(globalThis,'__madeiraLibraryPromises',{value:new Map()});
    const emit=x=>{if(budget-->0)try{globalThis.__madeiraLibraryEvent(JSON.stringify(x))}catch(_){}};
    const summary=x=>{if(x===null)return {type:'null'};if(Array.isArray(x))return {type:'array',count:x.length,cs2:x.some(a=>a===730||(a&&typeof a==='object'&&Object.getOwnPropertyDescriptor(a,'appid')?.value===730))};return {type:typeof x,...(typeof x==='string'?{count:x.length}:{})}};
    addEventListener('error',e=>emit({event:'error',name:e.error?.name||'Error',line:e.lineno,column:e.colno}));
    addEventListener('unhandledrejection',e=>emit({event:'unhandled-rejection',name:e.reason?.name||typeof e.reason}));
    const setup=()=>{const apps=globalThis.SteamClient?.Apps;if(!apps){if(lastApps!==false)emit({event:'binding',apps:false});lastApps=false;return;}
    if(lastApps!==true){emit({event:'binding',apps:true,argc:Object.getOwnPropertyNames(apps).length});for(const m of ['GetAppOverview','GetAppDetails','RegisterForAppOverviewChanges'])emit({event:'binding',method:m,apps:typeof Object.getOwnPropertyDescriptor(apps,m)?.value==='function'})}lastApps=true;for(const key of Object.getOwnPropertyNames(apps)){
      if(!/^(Get.*(App|Game|Library)|(UnregisterFor|RegisterFor).*(App|Game|Library)|BIs.*(Installed|Subscribed|Owned))/.test(key))continue;
      const d=Object.getOwnPropertyDescriptor(apps,key);if(!d||typeof d.value!=='function'||watched.has(d.value))continue;
      const fn=d.value;watched.add(fn);const wrapped=function(...args){if(budget<=0)return Reflect.apply(fn,this,args);const id=++serial;emit({event:'call',method:key,id,argc:args.length,cs2:args.includes(730)});

        let result;try{result=Reflect.apply(fn,this,args)}catch(e){emit({event:'throw',method:key,id,name:'Error'});throw e}
        try{const promise=result instanceof Promise;if(promise&&globalThis.__madeiraLibraryPromises.size<24)globalThis.__madeiraLibraryPromises.set(id,new WeakRef(result));const meta=summary(result);if(args[0]===730&&typeof result==='boolean'&&/^BIs/.test(key))meta.cs2=result;emit({event:'return',method:key,id,promise,result:meta})}catch(_){emit({event:'unavailable',method:key,id})}return result};
      try{Object.defineProperty(wrapped,'name',{value:fn.name});Object.defineProperty(wrapped,'length',{value:fn.length});
        Object.defineProperty(apps,key,{...d,value:wrapped});watched.add(wrapped)}catch(_){emit({event:'unavailable',method:key})}
    }};
    const run=()=>{try{setup()}catch(_){emit({event:'unavailable',method:'setup'})}};run();let attempts=0;const timer=setInterval(()=>{run();if(++attempts>=40)clearInterval(timer)},500);
    emit({event:'installed',path:location.pathname.startsWith('/library')?'library':'other'});
    })()
    """#
}
