// SPDX-License-Identifier: GPL-3.0-or-later
// Passive local CEF protocol observer. No page hooks, bindings or API wrappers.
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
    private var webSockets: [String: String] = [:]
    private var replies: [Int: ([String: Any]) -> Void] = [:]
    private var commands: [Int: String] = [:]
    private var discoveries = 0
    private var sampled: [String: Date] = [:]
    private var snapshots: [String: String] = [:]
    private var sampleCounts: [String: Int] = [:]
    private var uiSampled: [String: Date] = [:]
    private var uiSnapshots: [String: String] = [:]
    private var uiSampleCounts: [String: Int] = [:]
    private var sampleTasks: [String: Task<Void, Never>] = [:]
    private var targetLabels: [String: Int] = [:]
    private var storeTargets: Set<String> = []
    private var nextTargetLabel = 0
    private let session = URLSession(configuration: .ephemeral)

    static func safeURL(_ text: String) -> String {
        guard let u = URLComponents(string: text), let scheme = u.scheme,
              ["http", "https", "ws", "wss"].contains(scheme), let host = u.host else { return "[non-network-url]" }
        var c = URLComponents(); c.scheme = scheme; c.host = host; c.port = u.port
        c.path = u.path.replacingOccurrences(of: "[0-9]{12,}", with: "[id]", options: .regularExpression)
        return String((c.string ?? "[url]").prefix(240))
    }
    static func errorClass(_ text: String) -> String {
        let known = ["TypeError", "ReferenceError", "RangeError", "SyntaxError", "Remote call failed", "Failed to load", "Uncaught (in promise)", "NOTREACHED", "Check failed"]
        var classes = known.filter { text.contains($0) }
        if text.contains("A newer version of the Steam Client is required to run this application") { classes.append("AppLaunch_MustUpdateClient") }
        if text.contains("Steam must now be restarted in order to receive the latest update") { classes.append("Steam_ErrorCondition_RestartNeeded") }
        if text.contains("Steam client outdated") { classes.append("Steam_AppUpdateError_47") }
        if text.contains("An error occurred while launching this game: Update required") || text.contains("An error occurred while launching this game : Update required") { classes.append("GameLaunch_ContentUpdateRequired") }
        if let range = text.range(of: "reading '[A-Za-z_$][A-Za-z0-9_$]{0,63}'", options: .regularExpression) {
            classes.append("undefined-property=" + String(text[range].dropFirst(9).dropLast()))
        }
        return classes.isEmpty ? "unclassified" : classes.joined(separator: ",")
    }
    static func safeSnapshot(_ input: [String: Any]) -> String {
        var clean: [String: Any] = [:]
        for name in ["store", "ready", "cs2", "apps"] { if let value = input[name] as? Bool { clean[name] = value } }
        if let count = input["count"] as? Int, count >= 0, count <= 1_000_000 { clean["count"] = count }
        let bytes = (try? JSONSerialization.data(withJSONObject: clean, options: .sortedKeys)) ?? Data()
        return String(data: bytes, encoding: .utf8) ?? "{}"
    }
    // Console URL tracking is Steam's own route event. Return only fixed Library
    // paths/numeric AppIDs; never return arbitrary console text or query values.
    static func consoleLibraryRoute(_ values: [String]) -> String? {
        let text = values.prefix(4).map { String($0.prefix(1024)) }.joined(separator: " ")
        guard text.contains("[URLTrack]"), text.contains("Tracking page view") else { return nil }
        let pattern = #"/library(?:/(?:home|downloads|collections|app/[0-9]{1,10}))?(?=$|[?#\s'",)])"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let route = String(text[range])
        if route.hasPrefix("/library/app/"), let app = UInt64(route.dropFirst(13)), app > UInt32.max { return nil }
        return route
    }
    static func candidatePages(_ targets: [[String: Any]]) -> [[String: Any]] {
        targets.filter { target in
            guard target["type"] as? String == "page", target["id"] is String,
                  let text = target["url"] as? String else { return false }
            if text == "about:blank" { return true } // a Steam-owned popup may begin blank
            guard let url = URLComponents(string: text) else { return false }
            return ["http", "https"].contains(url.scheme ?? "") && url.host?.lowercased() == "steamloopback.host"
        }.sorted { left, right in
            func priority(_ target: [String: Any]) -> Int {
                let text = target["url"] as? String ?? "", path = URLComponents(string: text)?.path ?? ""
                return text == "about:blank" ? 3 : path.hasPrefix("/library") ? 0 : path == "/index.html" ? 1 : 2
            }
            let l = priority(left), r = priority(right)
            return l == r ? (left["id"] as? String ?? "") < (right["id"] as? String ?? "") : l < r
        }
    }
    static func safeUIState(_ input: [String: Any]) -> String {
        var clean: [String: Any] = [:]
        for name in ["dom", "failedToLoadText", "appLaunchClientUpdateText", "restartUpdateText", "clientOutdatedText", "appLaunchContentUpdateText", "updateRequiredText", "truncated"] {
            if let value = input[name] as? Bool { clean[name] = value }
        }
        let bytes = (try? JSONSerialization.data(withJSONObject: clean, options: .sortedKeys)) ?? Data()
        return String(data: bytes, encoding: .utf8) ?? "{}"
    }
    private func targetLabel(_ id: String) -> Int {
        if let label = targetLabels[id] { return label }
        nextTargetLabel += 1; targetLabels[id] = nextTargetLabel; return nextTargetLabel
    }
    private func targetNote(_ id: String, _ text: String, category: String = "navigation") {
        note("target=\(targetLabels[id] ?? 0) \(text)", category: category)
    }
    private func note(_ text: String, category: String = "navigation") {
        let limit = ["navigation": 25, "state": 20, "network": 24, "failure": 150, "warning": 30, "websocket": 35, "ui": 16][category] ?? 0
        guard emitted < 300, categories[category, default: 0] < limit else { return }
        emitted += 1; categories[category, default: 0] += 1
        LogStore.shared.log("[steam-library-v1] \(text)")
    }
    func start() {
        stop(); emitted = 0; events = 0; discoveries = 0; categories.removeAll()
        // MadeiraConfig.flag's production default is TRUE. TRACE_OFF must opt out.
        guard !MadeiraConfig.flag("MADEIRA_STEAM_LIBRARY_TRACE_OFF", fallback: false) else {
            note("observer=disabled setting=MADEIRA_STEAM_LIBRARY_TRACE_OFF"); return
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { note("observer-failed stage=socket errno=\(errno)", category: "failure"); return }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { let code = errno; close(fd); note("observer-failed stage=bind errno=\(code)", category: "failure"); return }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let code = errno; close(fd)
        guard named == 0 else { note("observer-failed stage=getsockname errno=\(code)", category: "failure"); return }
        port = Int(UInt16(bigEndian: address.sin_port))
        guard port >= 1024 else { note("observer-failed stage=port-selection", category: "failure"); port = 0; return }
        setenv("MADEIRA_STEAM_CDP_PORT", String(port), 1)
        note("observer=passive loopback=127.0.0.1 port=\(port) page-hooks=none; credentials and bodies excluded")
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
        for task in sampleTasks.values { task.cancel() }; sampleTasks.removeAll()
        for socket in sockets.values { socket.cancel(with: .goingAway, reason: nil) }
        sockets.removeAll(); requests.removeAll(); webSockets.removeAll(); sampled.removeAll(); snapshots.removeAll(); sampleCounts.removeAll()
        uiSampled.removeAll(); uiSnapshots.removeAll(); uiSampleCounts.removeAll(); targetLabels.removeAll(); storeTargets.removeAll(); nextTargetLabel = 0
        let waiting = Array(replies.values); replies.removeAll(); commands.removeAll(); port = 0; unsetenv("MADEIRA_STEAM_CDP_PORT")
        for reply in waiting { reply([:]) }
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
        let pages = Array(Self.candidatePages(targets).prefix(4)), wanted = Set(pages.compactMap { $0["id"] as? String })
        for id in Array(sockets.keys) where !wanted.contains(id) { disconnect(id) }
        for target in pages {
            guard let id = target["id"] as? String else { continue }
            if let socket = sockets[id] {
                updateRole(id, pageURL: target["url"] as? String ?? "")
                scheduleSamples(id, socket: socket); continue
            }
            guard sockets.count < 4, let address = target["webSocketDebuggerUrl"] as? String, let endpoint = URL(string: address),
                  ["127.0.0.1", "localhost"].contains(endpoint.host ?? ""), endpoint.port == port else { continue }
            await connect(id, endpoint: endpoint, pageURL: target["url"] as? String ?? "")
            if let socket = sockets[id] { scheduleSamples(id, socket: socket) }
        }
    }
    private func disconnect(_ id: String) {
        guard let socket = sockets.removeValue(forKey: id) else { return }
        let label = targetLabels[id] ?? 0
        sampleTasks.removeValue(forKey: id)?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        // Complete outstanding reads now rather than making a closed target's
        // timeout delay discovery of the replacement Steam browser.
        for commandID in Array(commands.keys) where commands[commandID]?.hasPrefix("target=\(label) ") == true {
            commands.removeValue(forKey: commandID); replies.removeValue(forKey: commandID)?([:])
        }
        requests = requests.filter { !$0.key.hasPrefix(id + ":") }; webSockets = webSockets.filter { !$0.key.hasPrefix(id + ":") }
        sampled.removeValue(forKey: id); snapshots.removeValue(forKey: id); sampleCounts.removeValue(forKey: id)
        uiSampled.removeValue(forKey: id); uiSnapshots.removeValue(forKey: id); uiSampleCounts.removeValue(forKey: id)
        targetLabels.removeValue(forKey: id); storeTargets.remove(id)
    }
    private func connect(_ id: String, endpoint: URL, pageURL: String) async {
        let socket = session.webSocketTask(with: endpoint); socket.maximumMessageSize = 2_000_000
        _ = targetLabel(id); sockets[id] = socket
        updateRole(id, pageURL: pageURL)
        socket.resume()
        targetNote(id, "page-attached role=\(storeTargets.contains(id) ? "steam-ui" : "blank-popup") url=\(Self.safeURL(pageURL))")
        Task { [weak self] in
            while let message = try? await socket.receive() {
                if case .string(let text) = message { await self?.receive(text, socket: socket) }
            }
            if self?.sockets[id] === socket { self?.disconnect(id) }
        }
        await send(socket, "Runtime.enable"); await send(socket, "Page.enable"); await send(socket, "Log.enable")
        await send(socket, "Network.enable", ["maxPostDataSize": 0, "maxTotalBufferSize": 1_048_576, "maxResourceBufferSize": 16_384])
    }
    private func updateRole(_ id: String, pageURL: String) {
        // A popup can navigate from about:blank without changing its target ID.
        // Use the latest discovery URL before deciding whether to query AppStore.
        if URLComponents(string: pageURL)?.host?.lowercased() == "steamloopback.host" { storeTargets.insert(id) }
        else { storeTargets.remove(id) }
    }
    private func scheduleSamples(_ id: String, socket: URLSessionWebSocketTask) {
        guard sampleTasks[id] == nil else { return }
        let current = generation
        sampleTasks[id] = Task { [weak self] in
            guard let self else { return }
            if self.storeTargets.contains(id) { await self.captureSnapshot(id, socket: socket) }
            if self.generation == current, self.sockets[id] === socket, !Task.isCancelled {
                await self.captureUIState(id, socket: socket)
            }
            if self.generation == current, self.sockets[id] === socket { self.sampleTasks.removeValue(forKey: id) }
        }
    }
    private func send(_ socket: URLSessionWebSocketTask, _ method: String, _ params: [String: Any] = [:]) async {
        sequence += 1
        await transmit(socket, id: sequence, method: method, params: params)
    }
    private func transmit(_ socket: URLSessionWebSocketTask, id: Int, method: String, params: [String: Any], purpose: String = "protocol") async {
        guard sockets.values.contains(where: { $0 === socket }) else { replies.removeValue(forKey: id)?([:]); return }
        let target = sockets.first(where: { $0.value === socket })?.key ?? "closed"
        if commands.count < 128 { commands[id] = "target=\(targetLabels[target] ?? 0) method=\(method) purpose=\(purpose)" }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]),
              let text = String(data: data, encoding: .utf8) else { replies.removeValue(forKey: id)?([:]); return }
        do { try await socket.send(.string(text)) }
        catch { commands.removeValue(forKey: id); replies.removeValue(forKey: id)?([:]) }
    }
    private func command(_ socket: URLSessionWebSocketTask, _ method: String, _ params: [String: Any], purpose: String) async -> [String: Any] {
        guard replies.count < 64, sockets.values.contains(where: { $0 === socket }) else { return [:] }
        sequence += 1; let id = sequence
        let target = sockets.first(where: { $0.value === socket })?.key ?? "closed"
        let label = targetLabels[target] ?? 0
        return await withCheckedContinuation { continuation in
            replies[id] = { continuation.resume(returning: $0) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let reply = self.replies.removeValue(forKey: id) else { return }
                self.commands.removeValue(forKey: id)
                self.note("target=\(label) CEF command-timeout method=\(method) purpose=\(purpose)", category: "failure"); reply([:])
            }
            Task { [weak self] in await self?.transmit(socket, id: id, method: method, params: params, purpose: purpose) }
        }
    }
    private func frames(_ stack: [String: Any]?, target: String, label: String, category: String = "failure") {
        for frame in (stack?["callFrames"] as? [[String: Any]] ?? []).prefix(6) {
            let raw = frame["functionName"] as? String ?? ""
            let name = raw.range(of: "^(async )?[A-Za-z_$][A-Za-z0-9_$.<>]{0,119}$", options: .regularExpression) == nil ? "[anonymous]" : raw
            targetNote(target, "\(label)-frame function=\(name) url=\(Self.safeURL(frame["url"] as? String ?? "")) line=\(frame["lineNumber"] as? Int ?? 0) column=\(frame["columnNumber"] as? Int ?? 0)", category: category)
        }
    }
    private static let observedEvents: Set<String> = [
        "Page.frameNavigated", "Page.navigatedWithinDocument", "Runtime.exceptionThrown", "Runtime.consoleAPICalled", "Log.entryAdded",
        "Network.requestWillBeSent", "Network.responseReceived", "Network.loadingFailed", "Network.loadingFinished",
        "Network.webSocketCreated", "Network.webSocketHandshakeResponseReceived", "Network.webSocketFrameError", "Network.webSocketClosed",
        "Network.webSocketFrameSent", "Network.webSocketFrameReceived"
    ]
    private func receive(_ text: String, socket: URLSessionWebSocketTask) async {
        guard sockets.values.contains(where: { $0 === socket }) else { return }
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = event["id"] as? Int {
            let command = commands.removeValue(forKey: id) ?? "unknown"
            if let error = event["error"] as? [String: Any] { note("CEF command-failed \(command) code=\(error["code"] as? Int ?? 0)", category: "failure") }
            if let callback = replies.removeValue(forKey: id) { callback(event["result"] as? [String: Any] ?? [:]) }
            return
        }
        let method = event["method"] as? String ?? "", p = event["params"] as? [String: Any] ?? [:]
        let target = sockets.first(where: { $0.value === socket })?.key ?? "closed"
        func key(_ id: String) -> String { target + ":" + id }
        guard Self.observedEvents.contains(method) else { return }
        // Replies, failures and route/error console records have independent
        // bounds. Startup dataReceived traffic must never manufacture a command
        // timeout or consume the first Library failure's observation budget.
        let important = ["Runtime.exceptionThrown", "Runtime.consoleAPICalled", "Log.entryAdded", "Page.frameNavigated", "Page.navigatedWithinDocument", "Network.loadingFailed", "Network.webSocketFrameError"].contains(method) ||
            (method == "Network.responseReceived" && ((p["response"] as? [String: Any])?["status"] as? Int ?? 0) >= 400)
        if events >= 8000 && !important {
            if method == "Network.loadingFinished", let id = p["requestId"] as? String { requests.removeValue(forKey: key(id)) }
            if method == "Network.webSocketClosed", let id = p["requestId"] as? String { webSockets.removeValue(forKey: key(id)) }
            return
        }
        if events < 8000 { events += 1 }
        if ["Page.frameNavigated", "Page.navigatedWithinDocument"].contains(method) {
            let url = (p["frame"] as? [String: Any])?["url"] as? String ?? p["url"] as? String ?? ""
            targetNote(target, "navigation library=\(url.contains("/library")) url=\(Self.safeURL(url))")
        } else if method == "Runtime.exceptionThrown", let detail = p["exceptionDetails"] as? [String: Any] {
            let exception = detail["exception"] as? [String: Any] ?? [:]
            let message = (detail["text"] as? String ?? "") + " " + (exception["description"] as? String ?? "")
            targetNote(target, "exception classes=\(Self.errorClass(message)) url=\(Self.safeURL(detail["url"] as? String ?? "")) line=\(detail["lineNumber"] as? Int ?? 0) column=\(detail["columnNumber"] as? Int ?? 0)", category: "failure")
            frames(detail["stackTrace"] as? [String: Any], target: target, label: "exception")
        } else if method == "Runtime.consoleAPICalled" {
            let args = p["args"] as? [[String: Any]] ?? []
            if let route = Self.consoleLibraryRoute(args.prefix(4).compactMap { $0["value"] as? String }) {
                targetNote(target, "console-route source=URLTrack route=\(route)")
            }
            let kind = p["type"] as? String ?? ""
            if ["error", "warning"].contains(kind) {
                let classes = args.prefix(8).map { Self.errorClass(($0["value"] as? String) ?? ($0["description"] as? String) ?? "") }
                let update = classes.contains { $0.contains("AppLaunch_MustUpdateClient") || $0.contains("Steam_ErrorCondition_RestartNeeded") || $0.contains("Steam_AppUpdateError_47") || $0.contains("GameLaunch_ContentUpdateRequired") }
                let category = kind == "warning" && !update ? "warning" : "failure"
                let types = args.prefix(8).map { value -> String in
                    let type = value["type"] as? String ?? "unknown"
                    return ["object", "function", "undefined", "string", "number", "boolean", "symbol", "bigint"].contains(type) ? type : "unknown"
                }
                targetNote(target, "console kind=\(kind) argc=\(args.count) types=\(types.joined(separator: ",")) classes=\(classes.joined(separator: ";"))", category: category)
                frames(p["stackTrace"] as? [String: Any], target: target, label: "console", category: category)
            }
        } else if method == "Log.entryAdded", let entry = p["entry"] as? [String: Any], ["error", "warning"].contains(entry["level"] as? String ?? "") {
            let category = entry["level"] as? String == "warning" ? "warning" : "failure"
            targetNote(target, "CEF-log classes=\(Self.errorClass(entry["text"] as? String ?? "")) url=\(Self.safeURL(entry["url"] as? String ?? "")) line=\(entry["lineNumber"] as? Int ?? 0)", category: category)
            frames(entry["stackTrace"] as? [String: Any], target: target, label: "CEF-log", category: category)
        } else if method == "Network.requestWillBeSent", let id = p["requestId"] as? String, let request = p["request"] as? [String: Any], requests.count < 512 {
            requests[key(id)] = (Self.safeURL(request["url"] as? String ?? ""), Date())
        } else if method == "Network.responseReceived", let response = p["response"] as? [String: Any] {
            let status = response["status"] as? Int ?? 0, url = Self.safeURL(response["url"] as? String ?? "")
            if status >= 400 || url.contains("library") || url.contains("chunk~") { targetNote(target, "resource status=\(status) url=\(url)", category: status >= 400 ? "failure" : "network") }
        } else if method == "Network.loadingFailed", let id = p["requestId"] as? String {
            let raw = p["errorText"] as? String ?? ""
            let code = raw.range(of: "^net::ERR_[A-Z0-9_]+$", options: .regularExpression) != nil ? raw : "unknown"
            targetNote(target, "resource-failed url=\(requests[key(id)]?.0 ?? "[unknown]") code=\(code) canceled=\(p["canceled"] as? Bool ?? false)", category: "failure")
            requests.removeValue(forKey: key(id))
        } else if method == "Network.loadingFinished", let id = p["requestId"] as? String { requests.removeValue(forKey: key(id))
        } else if method == "Network.webSocketCreated", let id = p["requestId"] as? String {
            let url = Self.safeURL(p["url"] as? String ?? "")
            if webSockets.count < 64 { webSockets[key(id)] = url }; targetNote(target, "websocket url=\(url)", category: "websocket")
        } else if method == "Network.webSocketHandshakeResponseReceived", let id = p["requestId"] as? String, let response = p["response"] as? [String: Any] {
            targetNote(target, "websocket handshake-status=\(response["status"] as? Int ?? 0) url=\(webSockets[key(id)] ?? "[unknown]")", category: "websocket")
        } else if method == "Network.webSocketFrameError", let id = p["requestId"] as? String {
            targetNote(target, "websocket transport-error url=\(webSockets[key(id)] ?? "[unknown]")", category: "failure")
        } else if method == "Network.webSocketClosed", let id = p["requestId"] as? String { webSockets.removeValue(forKey: key(id))
        } else if ["Network.webSocketFrameSent", "Network.webSocketFrameReceived"].contains(method), let frame = p["response"] as? [String: Any], let payload = frame["payloadData"] as? String {
            targetNote(target, "websocket direction=\(method.hasSuffix("Sent") ? "send" : "receive") bytes=\(payload.utf8.count) opcode=\(frame["opcode"] as? Int ?? 0)", category: "websocket")
        }
        expireRequests()
    }
    private func expireRequests() {
        for (id, value) in requests where Date().timeIntervalSince(value.1) > 30 {
            note("resource-timeout url=\(value.0)", category: "failure"); requests.removeValue(forKey: id)
        }
    }
    private func captureSnapshot(_ id: String, socket: URLSessionWebSocketTask) async {
        guard sampleCounts[id, default: 0] < 120, Date().timeIntervalSince(sampled[id] ?? .distantPast) >= 5 else { return }
        sampled[id] = Date(); sampleCounts[id, default: 0] += 1
        let result = await command(socket, "Runtime.evaluate", ["expression": Self.snapshotExpression, "returnByValue": true, "throwOnSideEffect": true, "timeout": 500], purpose: "store")
        guard sockets[id] === socket, !Task.isCancelled else { return }
        if result["exceptionDetails"] != nil {
            if snapshots[id] != "unavailable" { targetNote(id, "readonly-store-snapshot=unavailable side-effect-check=retained", category: "state"); snapshots[id] = "unavailable" }
        } else if let value = (result["result"] as? [String: Any])?["value"] as? [String: Any] {
            let clean = Self.safeSnapshot(value)
            if snapshots[id] != clean { targetNote(id, "readonly-store \(clean)", category: "state"); snapshots[id] = clean }
        }
    }
    private func captureUIState(_ id: String, socket: URLSessionWebSocketTask) async {
        guard uiSampleCounts[id, default: 0] < 8, Date().timeIntervalSince(uiSampled[id] ?? .distantPast) >= 15 else { return }
        uiSampled[id] = Date(); uiSampleCounts[id, default: 0] += 1
        let result = await command(socket, "Runtime.evaluate", ["expression": Self.uiMessageExpression, "returnByValue": true, "throwOnSideEffect": true, "timeout": 500], purpose: "known-ui-text")
        guard sockets[id] === socket, !Task.isCancelled else { return }
        if result["exceptionDetails"] != nil {
            if uiSnapshots[id] != "unavailable" { targetNote(id, "readonly-ui-text=unavailable side-effect-check=retained", category: "ui"); uiSnapshots[id] = "unavailable" }
        } else if let value = (result["result"] as? [String: Any])?["value"] as? [String: Any] {
            let clean = Self.safeUIState(value)
            if uiSnapshots[id] != clean {
                targetNote(id, "readonly-ui-text visibility=unproven \(clean)", category: "ui"); uiSnapshots[id] = clean
                if value["appLaunchClientUpdateText"] as? Bool == true { targetNote(id, "known-text-match key=AppLaunch_MustUpdateClient_Description visibility=unproven", category: "failure") }
                if value["restartUpdateText"] as? Bool == true { targetNote(id, "known-text-match key=Steam_ErrorCondition_RestartNeeded visibility=unproven", category: "failure") }
                if value["clientOutdatedText"] as? Bool == true { targetNote(id, "known-text-match key=Steam_AppUpdateError_47 visibility=unproven", category: "failure") }
                if value["appLaunchContentUpdateText"] as? Bool == true { targetNote(id, "known-text-match key=AppLaunchError_Text+Steam_AppUpdateError_19 visibility=unproven", category: "failure") }
                if value["updateRequiredText"] as? Bool == true { targetNote(id, "known-text-match text=Update-required attribution=ambiguous visibility=unproven", category: "failure") }
                if value["failedToLoadText"] as? Bool == true { targetNote(id, "known-text-match text=Failed-to-load visibility=unproven", category: "failure") }
            }
        }
    }
    // Separate, read-only text matching cannot hide a successful AppStore sample.
    // Only booleans leave CEF; hidden text/localization templates are not proof
    // that a message was displayed. Never return arbitrary DOM/body content.
    static let uiMessageExpression = #"""
    (()=>{const b=globalThis.document?.body;if(!b)return {dom:false};const raw=b.textContent||'',t=raw.slice(0,65536).replace(/\s+/g,' ');return {dom:true,truncated:raw.length>65536,failedToLoadText:t.includes('Failed to load'),appLaunchClientUpdateText:t.includes('A newer version of the Steam Client is required to run this application'),restartUpdateText:t.includes('Steam must now be restarted in order to receive the latest update'),clientOutdatedText:t.includes('Steam client outdated'),appLaunchContentUpdateText:t.includes('An error occurred while launching this game: Update required')||t.includes('An error occurred while launching this game : Update required'),updateRequiredText:t.includes('Update Required')||t.includes('Update required')}})()
    """#
    // Evaluated in place with Chromium's side-effect check. No setters, listeners,
    // page globals, native API calls, script replacement or promise handlers.
    static let snapshotExpression = #"""
    (()=>{const s=globalThis.appStore,m=s?.m_mapApps;return {store:!!s,ready:typeof s?.m_bIsInitialized==='boolean'?s.m_bIsInitialized:undefined,count:m&&Number.isInteger(m.size)?m.size:undefined,cs2:m&&typeof m.has==='function'?m.has(730):undefined,apps:!!globalThis.SteamClient?.Apps}})()
    """#
}
