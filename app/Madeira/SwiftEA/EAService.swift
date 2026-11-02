// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// The EA app's local service, stood in for by Madeira while an EA game runs
// (docs/EA.md, "Playing"). An EA game connects to 127.0.0.1:3216 as it starts
// and asks, in small XML messages ("LSX"), who is signed in, which content it
// may run, for a sign-in code of its own, and for a licence token. Without an
// answer the game shows the EA app's "not running" error or quits. Madeira
// listens on the same port inside its own process (Wine's sockets are the
// app's), answers from the signed-in account, and asks EA's servers for what it
// cannot answer itself. The message set follows Maxima (GPL-3.0); no Maxima code
// is included. Friends, presence and the in-game overlay are answered as empty.

/// What the service answers for the game being started.
struct EAServiceContext: Sendable {
    var offerID: String
    var contentID: String
    var title: String
    var version: String
    var multiplayerID: String
    var userID: String
    var personaID: String
    var displayName: String
    var profile: EAHardwareProfile
    var hashVersion: Int
}

final class EAService: @unchecked Sendable {
    static let shared = EAService()
    static let port: UInt16 = 3216
    static let languages = "ar_SA,de_DE,en_US,es_ES,es_MX,fr_FR,it_IT,ja_JP,ko_KR,pl_PL,pt_BR,ru_RU,zh_CN,zh_TW"
    /// What the EA app's own service announces itself as.
    private static let challengeBuild = "release"
    private static let challengeVersion = "10,5,30,15625"

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var thread: Thread?
    private var stopping = false
    private var context: EAServiceContext?
    private var connections = 0
    private let api: EAAPI

    init(api: EAAPI = .shared) { self.api = api }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener >= 0 }

    /// Listens for the game, for `context`. Idempotent: a running service takes the new context.
    func start(_ context: EAServiceContext) throws {
        lock.lock(); defer { lock.unlock() }
        self.context = context
        guard listener < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw EAAPIError.invalid("service-socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            EALog.event("[ea-service] listen failed reason=\(reason)")
            throw EAAPIError.invalid("service-listen")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        listener = fd
        stopping = false
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "EA local service"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
        EALog.event("[ea-service] listening port=\(Self.port) offer=\(context.offerID)")
    }

    func stop() {
        lock.lock()
        guard listener >= 0 else { lock.unlock(); return }
        stopping = true
        close(listener)
        listener = -1
        context = nil
        lock.unlock()
        EALog.event("[ea-service] stopped")
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    private func currentContext() -> EAServiceContext? { lock.lock(); defer { lock.unlock() }; return context }

    private func acceptLoop(_ fd: Int32) {
        while !isStopping {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 500)
            if ready <= 0 { continue }
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            guard client >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock(); connections += 1; let number = connections; lock.unlock()
            EALog.event("[ea-service] connection \(number) opened")
            let connection = Connection(fd: client, number: number, service: self)
            let thread = Thread { connection.run() }
            thread.name = "EA local service \(number)"
            thread.start()
        }
    }

    // MARK: - One connection

    private final class Connection {
        let fd: Int32
        let number: Int
        unowned let service: EAService
        private var challenge: String
        private var sessionKey: [UInt8]?
        /// Set when the challenge is accepted; encryption starts with the next message.
        private var pendingKey: [UInt8]?
        private var pending = ""

        init(fd: Int32, number: Int, service: EAService) {
            self.fd = fd; self.number = number; self.service = service
            var bytes = ""
            for _ in 0..<16 { bytes += String(format: "%02x", UInt8.random(in: 0...255)) }
            challenge = bytes
        }

        func run() {
            defer { close(fd); EALog.event("[ea-service] connection \(number) closed") }
            // The service speaks first: its challenge.
            send(EALSX.event(EAXML.element("Challenge", [("build", EAService.challengeBuild), ("key", challenge), ("version", EAService.challengeVersion)])))
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !service.isStopping {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 500)
                if ready == 0 { continue }
                if ready < 0 { return }
                let count = recv(fd, &buffer, buffer.count, 0)
                if count <= 0 { return }
                receive(Data(buffer[0..<count]))
            }
        }

        private func receive(_ data: Data) {
            // Messages end with a NUL; a packet may hold several or part of one.
            var text = String(decoding: data, as: UTF8.self)
            if let key = sessionKey {
                guard let plain = EALSXCrypto.decrypt(text.replacingOccurrences(of: "\0", with: ""), key: key) else {
                    EALog.event("[ea-service] connection \(number): a message could not be decrypted")
                    return
                }
                text = plain
            }
            pending += text.replacingOccurrences(of: "\0", with: "")
            let documents = EALSX.documents(in: pending)
            if let last = documents.last, let range = pending.range(of: last, options: .backwards) {
                pending = String(pending[range.upperBound...])
            }
            if pending.count > 64 * 1024 { pending = "" }
            for document in documents { handle(document) }
        }

        private func send(_ message: String) {
            var text = message
            if let key = sessionKey { text = EALSXCrypto.encrypt(message, key: key) }
            text += "\0"
            let bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let sent = bytes.withUnsafeBufferPointer { pointer in Darwin.send(fd, pointer.baseAddress! + offset, bytes.count - offset, 0) }
                if sent <= 0 { return }
                offset += sent
            }
            if let pendingKey { sessionKey = pendingKey; self.pendingKey = nil }
        }

        private func handle(_ document: String) {
            guard let request = EALSX.request(document) else {
                if !EALSX.isEvent(document) { EALog.event("[ea-service] connection \(number): unreadable message") }
                return
            }
            guard let context = service.currentContext() else { return }
            if request.name != "ChallengeResponse" {
                EALog.event("[ea-service] connection \(number): \(request.name)")
            }
            let semaphore = DispatchSemaphore(value: 0)
            var body: String?
            let api = service.api
            Task.detached(priority: .userInitiated) { [self] in
                body = await self.answer(request, context: context, api: api)
                semaphore.signal()
            }
            semaphore.wait()
            if let body { send(EALSX.response(to: request, body)) }
        }

        /// The response body for a request, or nil for one that gets no answer.
        private func answer(_ request: EALSXRequest, context: EAServiceContext, api: EAAPI) async -> String? {
            switch request.name {
            case "ChallengeResponse":
                guard let response = request.attribute("response"), EALSXCrypto.checkChallengeResponse(response, challenge: challenge) else {
                    EALog.event("[ea-service] connection \(number): wrong challenge response")
                    return nil
                }
                let accepted = EALSXCrypto.challengeResponse(request.attribute("key") ?? "")
                let version = request.attribute("version") ?? "2"
                guard let key = EALSXCrypto.sessionKey(version: version, acceptedKey: accepted) else {
                    EALog.event("[ea-service] connection \(number): unknown encryption version \(version)")
                    return nil
                }
                EALog.event("[ea-service] connection \(number): game connected title=\"\(request.value("Title") ?? "")\" content=\(request.value("ContentId") ?? "") encryption=\(version)")
                pendingKey = key
                return EAXML.element("ChallengeAccepted", [("response", accepted)])

            case "GetConfig":
                let services: [(String, String)] = [
                    ("EbisuSDK", "SDK"), ("EbisuSDK", "PROFILE"), ("XMPP", "PRESENCE"), ("XMPP", "FRIENDS"), ("Commerce", "COMMERCE"),
                    ("EbisuSDK", "RECENTPLAYER"), ("EbisuSDK", "IGO"), ("EbisuSDK", "MISC"), ("EALS", "LOGIN"), ("EbisuSDK", "UTILITY"),
                    ("XMPP", "XMPP"), ("XMPP", "CHAT"), ("EbisuSDK", "IGO_EVENT"), ("EALS", "EALS_EVENTS"), ("EbisuSDK", "LOGIN_EVENT"),
                    ("XMPP", "INVITE_EVENT"), ("EbisuSDK", "PROFILE_EVENT"), ("XMPP", "PRESENCE_EVENT"), ("XMPP", "FRIENDS_EVENT"),
                    ("Commerce", "COMMERCE_EVENT"), ("XMPP", "CHAT_EVENT"), ("EbisuSDK", "DOWNLOAD_EVENT"), ("EbisuSDK", "PERMISSION"),
                    ("EbisuSDK", "RESOURCES"), ("EbisuSDK", "BLOCKED_USERS"), ("EbisuSDK", "BLOCKED_USER_EVENT"), ("EbisuSDK", "GET_USERID"),
                    ("EbisuSDK", "ONLINE_STATUS_EVENT"), ("EbisuSDK", "ACHIEVEMENT"), ("EbisuSDK", "ACHIEVEMENT_EVENT"),
                    ("EbisuSDK", "BROADCAST_EVENT"), ("PI", "PROGRESSIVE_INSTALLATION"), ("PI", "PROGRESSIVE_INSTALLATION_EVENT"),
                    ("EbisuSDK", "CONTENT"),
                ]
                return EAXML.element("GetConfigResponse", children: services.map { EAXML.element("Service", [("Name", $0.0), ("Facility", $0.1)]) }.joined())

            case "GetProfile":
                return EAXML.element("GetProfileResponse", [
                    ("Persona", context.displayName), ("SubscriberLevel", "0"), ("CommerceCurrency", "USD"), ("IsTrialSubscriber", "false"),
                    ("Country", "US"), ("UserId", context.userID), ("GeoCountry", "US"), ("AvatarId", ""), ("IsSubscriber", "false"),
                    ("IsSteamSubscriber", "false"), ("PersonaId", context.personaID.isEmpty ? "0" : context.personaID), ("IsUnderAge", "false"),
                    ("UserIndex", "0"),
                ])

            case "GetSetting":
                let setting: String
                switch request.attribute("SettingId") ?? "" {
                case "Environment": setting = "production"
                default: setting = "false"   // IsIgoEnabled, IsIgoAvailable
                }
                return EAXML.element("GetSettingResponse", [("Setting", setting)])

            case "GetInternetConnectedState":
                return EAXML.element("InternetConnectedState", [("connected", "1")])

            case "GetGameInfo":
                let info: String
                switch request.attribute("GameInfoId")?.uppercased() ?? "" {
                case "LANGUAGES": info = EAService.languages
                case "INSTALLED_LANGUAGE": info = "en_US"
                default: info = "false"   // FREE_TRIAL
                }
                return EAXML.element("GetGameInfoResponse", [("GameInfo", info)])

            case "GetAllGameInfo":
                let now = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "Z", with: "")
                return EAXML.element("GetAllGameInfoResponse", [
                    ("FullGamePurchased", "true"), ("FullGameReleased", "true"), ("InstalledVersion", context.version.isEmpty ? "0" : context.version),
                    ("MaxGroupSize", "16"), ("Languages", EAService.languages), ("Expiration", "0000-00-00T00:00:00"), ("UpToDate", "true"),
                    ("HasExpiration", "false"), ("InstalledLanguage", "en_US"), ("EntitlementSource", "EA"), ("FullGameReleaseDate", "2000-01-01T00:00:00"),
                    ("AvailableVersion", context.version.isEmpty ? "1.0" : context.version), ("DisplayName", context.title), ("FreeTrial", "false"),
                    ("SystemTime", now),
                ])

            case "GetAuthCode":
                let clientID = request.attribute("ClientId") ?? ""
                let scopes = (request.attribute("Scope") ?? "").split(separator: " ").map(String.init)
                var code = "invalid"
                do {
                    code = try await api.exchange(clientID: clientID, responseType: "code", scopes: scopes, profile: context.profile)
                } catch {
                    EALog.event("[ea-service] auth code for \(clientID) failed reason=\((error as? EAAPIError)?.reason ?? String(describing: type(of: error)))")
                }
                return EAXML.element("AuthCode", [("value", code)])

            case "RequestLicense":
                // A game asking for its licence token (a Denuvo ticket) at start.
                let (hash, _) = context.profile.machineHash(version: context.hashVersion)
                do {
                    let (xml, _) = try await api.license(contentID: context.contentID, machineHash: hash,
                                                         ticket: request.attribute("RequestTicket"), engine: request.attribute("TicketEngine"))
                    guard let info = EALicenseInfo(xml: xml), let token = info.gameToken else {
                        EALog.event("[ea-service] licence request: no token")
                        return EAXML.element("RequestLicenseResponse", [("License", "")])
                    }
                    return EAXML.element("RequestLicenseResponse", [("License", token)])
                } catch {
                    EALog.event("[ea-service] licence request failed reason=\((error as? EAAPIError)?.reason ?? String(describing: type(of: error)))")
                    return EAXML.element("RequestLicenseResponse", [("License", "")])
                }

            case "QueryEntitlements":
                let group = request.attribute("Group") ?? ""
                let entitlements = (try? await api.entitlements(group: group)) ?? []
                let children = entitlements.map { e in
                    EAXML.element("Entitlement", [
                        ("LastModifiedDate", "0000-00-00T00:00:00"), ("EntitlementId", e.id), ("UseCount", String(e.useCount)),
                        ("Version", String(e.version)), ("ItemId", e.productID), ("ResourceId", ""), ("GrantDate", e.grantDate), ("Group", group),
                        ("EntitlementTag", e.tag), ("Type", e.type), ("Expiration", e.terminationDate ?? "0000-00-00T00:00:00"), ("Source", ""),
                    ])
                }.joined()
                return EAXML.element("QueryEntitlementsResponse", children: children)

            case "GetPresence":
                return EAXML.element("GetPresenceResponse", [("UserId", context.userID), ("Presence", "INGAME")])

            case "SetPresence", "SetDownloaderUtilization":
                return EAXML.element("ErrorSuccess", [("Code", "0"), ("Description", "")])

            case "GetBlockList":
                return EAXML.element("GetBlockListResponse", [("Return", "Success")])

            case "QueryFriends":
                return EAXML.element("QueryFriendsResponse")

            case "QueryPresence":
                return EAXML.element("QueryPresenceResponse")

            case "QueryOffers":
                return EAXML.element("QueryOffersResponse")

            case "QueryImage":
                return EAXML.element("QueryImageResponse", [("Result", "0")])

            case "GetVoipStatus":
                return EAXML.element("GetVoipStatusResponse", [("Available", "false"), ("Active", "false")])

            case "IsProgressiveInstallationAvailable":
                return EAXML.element("IsProgressiveInstallationAvailableResponse", [("ItemId", request.attribute("ItemId") ?? context.offerID), ("Available", "false")])

            case "AreChunksInstalled":
                let chunks = request.body.children("ChunkIds").flatMap { $0.children }.map { EAXML.element("ChunkId", children: EAXML.escape($0.text)) }.joined()
                return EAXML.element("AreChunksInstalledResponse", [("ItemId", request.attribute("ItemId") ?? context.offerID), ("Installed", "true")], children: chunks)

            case "ShowIGOWindow":
                return nil

            default:
                EALog.event("[ea-service] connection \(number): no answer for \(request.name)")
                return nil
            }
        }
    }
}
