// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 llamajose
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Steam's local network game transfers (docs/STEAM_LIBRARY.md, "From a PC on
// this network"): chunks of a depot come from Valve's client on a PC in the
// same network that has the game installed, instead of from a content server.
// The message types and fields are Valve's (steammessages_remoteclient_discovery,
// steammessages_contentsystem and steammessages_clientlanp2p protobufs).
//
// 1. This device joins the account's remote clients: RemoteClient.NotifyOnline
//    and its status (CMsgRemoteClientBroadcastStatus) relayed to the other
//    clients with RemoteClient.SendSteamBroadcastPacket. Their statuses come
//    back the same way (SteamLANRelay), with the PC's addresses and client ID.
// 2. Discovery: one CMsgRemoteClientBroadcastDiscovery sent straight to the
//    PC's UDP port 27036 (no broadcast: iOS gives sideloaded apps no multicast
//    entitlement). The PC answers with its status and asks for this device's,
//    which is answered; the PC then counts it as one of the account's devices.
// 3. ContentServerDirectory.RequestPeerContentServer (DepotDownloader, over the
//    app's CM connection) asks Steam to open that PC's content server for the
//    app: a TCP port, the depots it has and an access token.
// 4. Chunks: k_EMsgClientPeerChunkRequest / k_EMsgClientPeerChunkResponse on
//    that TCP connection, framed like every Steam TCP message (length, "VT01",
//    message type with the protobuf flag, header length 0, body), several
//    requests in flight at once and answers matched by chunk SHA-1.

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Settings › Steam › "Downloads from PCs on this network": on/off, an
/// optional fixed PC address (found through Steam when empty), and this
/// device's own client ID for Steam's local network messages (random, kept).
enum SteamLANSetting {
    static let enabledKey = "madeira.steam.lanEnabled"
    static let hostKey = "madeira.steam.lanPeerHost"
    static let clientIDKey = "madeira.steam.lanClientID"

    /// Off until turned on; on for an install that already had a PC address
    /// (decided once, so clearing the address later does not turn it off).
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                UserDefaults.standard.set(!host.isEmpty, forKey: enabledKey)
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let lastHostKey = "madeira.steam.lanLastHost"

    /// The address of the last PC that served a download, tried when Steam relays no PC.
    static var lastHost: String {
        get { UserDefaults.standard.string(forKey: lastHostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastHostKey) }
    }

    /// A fixed PC address, "" to find the PC through Steam.
    static var host: String {
        get { (UserDefaults.standard.string(forKey: hostKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let value = newValue.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { UserDefaults.standard.removeObject(forKey: hostKey) }
            else { UserDefaults.standard.set(value, forKey: hostKey) }
        }
    }

    static let peerClientIDKey = "madeira.steam.lanPeerClientID"

    /// The last PC that served a download (its Steam client ID), tried first. 0 = none.
    static var peerClientID: UInt64 {
        get { UInt64(UserDefaults.standard.string(forKey: peerClientIDKey) ?? "") ?? 0 }
        set {
            if newValue == 0 { UserDefaults.standard.removeObject(forKey: peerClientIDKey) }
            else { UserDefaults.standard.set(String(newValue), forKey: peerClientIDKey) }
        }
    }

    static func isValidAddress(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }

    /// Never 0 and stable across launches (Steam keys the PC's permission to it).
    static var localClientID: UInt64 {
        if let stored = UserDefaults.standard.string(forKey: clientIDKey), let id = UInt64(stored), id != 0 { return id }
        var id: UInt64 = 0
        while id == 0 { id = UInt64.random(in: 1...UInt64.max) }
        UserDefaults.standard.set(String(id), forKey: clientIDKey)
        return id
    }
}

/// What a PC's Steam client says about itself on the local network.
struct SteamLANPeerStatus: Sendable, Equatable {
    var clientID: UInt64
    var hostname: String
    var users: [UInt64]
    /// Its IP addresses (ip_addresses), LAN ones among VPN and virtual adapters.
    var addresses: [String] = []
}

/// What Steam relays between this account's clients while Madeira is signed in:
/// their statuses (kept for a few minutes), and this device's own status to
/// answer their discovery with.
final class SteamLANRelay: @unchecked Sendable {
    static let shared = SteamLANRelay()
    private let lock = NSLock()
    private var statuses: [UInt64: (status: SteamLANPeerStatus, seen: Date)] = [:]
    private var own: (clientID: UInt64, status: Data)?

    /// Returns true for a client not seen before or with new addresses.
    @discardableResult func record(_ status: SteamLANPeerStatus) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = statuses[status.clientID]?.status.addresses != status.addresses
        statuses[status.clientID] = (status, Date())
        return changed
    }

    /// Statuses of the account's other clients seen in the last `maximumAge` seconds.
    func recent(excluding clientID: UInt64, maximumAge: TimeInterval = 300) -> [SteamLANPeerStatus] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return statuses.values.filter { $0.status.clientID != clientID && now.timeIntervalSince($0.seen) <= maximumAge }
            .sorted { $0.seen > $1.seen }.map(\.status)
    }

    func setOwn(clientID: UInt64, status: Data) { lock.lock(); own = (clientID, status); lock.unlock() }
    var ownStatus: (clientID: UInt64, status: Data)? { lock.lock(); defer { lock.unlock() }; return own }
}

enum SteamLANPeer {
    static let discoveryPort: UInt16 = 27036
    /// 0xFFFFFFFFA05F4C21, little-endian, at the start of every discovery datagram.
    /// On the wire FF FF FF FF 21 4C 5F A0, as a PC's Steam client sends its
    /// status (captured from Steam on Windows, 2026-10-29); the reversed order is ignored.
    static let discoveryMagic: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x21, 0x4C, 0x5F, 0xA0]
    static let peerChunkRequest: UInt32 = 9902   // k_EMsgClientPeerChunkRequest
    static let peerChunkResponse: UInt32 = 9903  // k_EMsgClientPeerChunkResponse
    static let tcpMagic: [UInt8] = Array("VT01".utf8)

    // MARK: Discovery datagrams

    /// A discovery request from `clientID` (ERemoteClientBroadcastMsg 0).
    static func discoveryPacket(clientID: UInt64, sequence: UInt32) -> Data {
        var header = ProtobufEncoder()
        header.writeUInt64(fieldNumber: 1, value: clientID)   // client_id
        header.writeTag(fieldNumber: 2, wireType: .varint)     // msg_type = Discovery (0), written explicitly
        header.writeVarint(0)
        var body = ProtobufEncoder()
        body.writeUInt32(fieldNumber: 1, value: sequence)      // seq_num
        var packet = Data(discoveryMagic)
        append32(&packet, UInt32(header.data.count)); packet.append(header.data)
        append32(&packet, UInt32(body.data.count)); packet.append(body.data)
        return packet
    }

    /// This device's status (ERemoteClientBroadcastMsg 1), as a Steam client
    /// sends it in answer to a discovery: header client_id, msg_type 1 and
    /// instance_id, as Steam on Windows sends (captured 2026-10-29); body
    /// CMsgRemoteClientBroadcastStatus.
    static func statusPacket(clientID: UInt64, instanceID: UInt64, steamID: UInt64, hostname: String, lanIP: String) -> Data {
        var header = ProtobufEncoder()
        header.writeUInt64(fieldNumber: 1, value: clientID)     // client_id
        header.writeUInt64(fieldNumber: 2, value: 1)            // msg_type = Status
        header.writeUInt64(fieldNumber: 3, value: instanceID)   // instance_id
        var user = ProtobufEncoder()
        user.writeFixed64(fieldNumber: 1, value: steamID)       // steamid
        user.writeUInt32(fieldNumber: 2, value: 1)              // auth_key_id
        var body = ProtobufEncoder()
        body.writeInt32(fieldNumber: 1, value: 8)               // version
        body.writeInt32(fieldNumber: 2, value: 6)               // min_version
        body.writeUInt32(fieldNumber: 3, value: UInt32(discoveryPort)) // connect_port
        body.writeString(fieldNumber: 4, value: hostname)
        body.writeInt32(fieldNumber: 7, value: -102)            // ostype: macOS, as at logon
        body.writeBool(fieldNumber: 8, value: true)             // is64bit
        body.writeSubmessage(fieldNumber: 9, value: user.data)  // users
        body.writeInt32(fieldNumber: 11, value: 1)              // euniverse: public
        body.writeUInt32(fieldNumber: 12, value: UInt32(Date().timeIntervalSince1970)) // timestamp
        if !lanIP.isEmpty { body.writeString(fieldNumber: 20, value: lanIP) } // ip_addresses
        body.writeUInt32(fieldNumber: 23, value: 2)             // supported_services, as Steam on Windows
        body.writeUInt32(fieldNumber: 31, value: 1)             // gaming_device_type
        var packet = Data(discoveryMagic)
        append32(&packet, UInt32(header.data.count)); packet.append(header.data)
        append32(&packet, UInt32(body.data.count)); packet.append(body.data)
        return packet
    }

    /// The msg_type in a discovery-format packet's header, or nil.
    static func packetType(_ bytes: [UInt8]) -> UInt64? {
        guard bytes.count >= 12, Array(bytes[0..<8]) == discoveryMagic else { return nil }
        let headerLength = Int(read32(bytes, 8))
        guard headerLength >= 0, 12 + headerLength <= bytes.count else { return nil }
        var type: UInt64 = 0
        var h = ProtobufDecoder(Data(bytes[12..<(12 + headerLength)]))
        while let t = try? h.readTag() {
            if t.fieldNumber == 2, t.wireType == .varint { type = (try? h.readVarint()) ?? 0 }
            else if (try? h.skip(wireType: t.wireType)) == nil { return nil }
        }
        return type
    }

    /// The status a Steam client answers with (ERemoteClientBroadcastMsg 1), or nil.
    static func parseStatus(_ packet: Data) -> SteamLANPeerStatus? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 16, Array(bytes[0..<8]) == discoveryMagic else { return nil }
        let headerLength = Int(read32(bytes, 8))
        guard headerLength >= 0, 12 + headerLength + 4 <= bytes.count else { return nil }
        let header = Data(bytes[12..<(12 + headerLength)])
        let bodyLength = Int(read32(bytes, 12 + headerLength))
        let bodyStart = 16 + headerLength
        guard bodyLength >= 0, bodyStart + bodyLength <= bytes.count else { return nil }
        let body = Data(bytes[bodyStart..<(bodyStart + bodyLength)])

        var clientID: UInt64 = 0
        var type: UInt64 = 0
        var decoder = ProtobufDecoder(header)
        while let tag = try? decoder.readTag() {
            switch tag.fieldNumber {
            case 1: clientID = (try? decoder.readVarint()) ?? 0
            case 2: type = (try? decoder.readVarint()) ?? 0
            default: guard (try? decoder.skip(wireType: tag.wireType)) != nil else { return nil }
            }
        }
        guard type == 1, clientID != 0 else { return nil }

        var status = SteamLANPeerStatus(clientID: clientID, hostname: "", users: [])
        var fields = ProtobufDecoder(body)
        while let tag = try? fields.readTag() {
            switch tag.fieldNumber {
            case 4: status.hostname = (try? fields.readString()) ?? ""
            case 20: if let address = try? fields.readString() { status.addresses.append(address) }
            case 9:
                guard let user = try? fields.readBytes() else { return status }
                var u = ProtobufDecoder(user)
                while let t = try? u.readTag() {
                    if t.fieldNumber == 1, t.wireType == .fixed64, let id = try? u.readFixed64() { status.users.append(id) }
                    else if (try? u.skip(wireType: t.wireType)) == nil { break }
                }
            default: guard (try? fields.skip(wireType: tag.wireType)) != nil else { return status }
            }
        }
        return status
    }

    /// What one discovery round saw, for the log.
    struct DiscoveryReport: Sendable {
        var status: SteamLANPeerStatus?
        /// Where the status came from (the PC may answer from another of its addresses).
        var from = ""
        var note = ""
    }

    /// Ask the Steam client at `host` (an IPv4 address) for its status. Blocking;
    /// call it off the main actor. Tries a few times, `timeout` seconds each.
    static func discover(host: String, clientID: UInt64, status ownStatus: Data? = nil,
                         attempts: Int = 3, timeout: TimeInterval = 1.5) -> DiscoveryReport {
        var report = DiscoveryReport()
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = discoveryPort.bigEndian
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { report.note = "bad address"; return report }

        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd >= 0 else { report.note = "socket errno=\(errno)"; return report }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // The answer may go to the discovery port or to the sender's port:
        // listen on 27036 when it is free, else on any port.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = discoveryPort.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var boundPort = Int(discoveryPort)
        if bound != 0 {
            local.sin_port = 0
            _ = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            boundPort = 0
        }
        setTimeout(fd, timeout)

        var sent = 0, sendErrno: Int32 = 0, datagrams = 0, answered = 0, others: [String] = []
        for attempt in 0..<max(1, attempts) {
            if report.status != nil { break }
            let packet = [UInt8](discoveryPacket(clientID: clientID, sequence: UInt32(attempt + 1)))
            let rc = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == packet.count { sent += 1 } else { sendErrno = errno }
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 2048)
            while Date() < deadline {
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
                }
                guard n > 0 else { break }  // timeout
                datagrams += 1
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = from.sin_addr
                inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
                let source = String(cString: text)
                // The PC asks for this device's status (a discovery of its own):
                // answer it, as a Steam client does.
                if let own = ownStatus, packetType(Array(buffer[0..<n])) == 0 {
                    let reply = [UInt8](own)
                    _ = withUnsafePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, reply, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    answered += 1
                    continue
                }
                // Any Steam client's status counts: the PC may answer from
                // another of its addresses, or by broadcast.
                if report.status == nil, let status = parseStatus(Data(buffer[0..<n])), status.clientID != clientID {
                    report.status = status
                    report.from = source
                    // Tell the PC about this device too, then stay a moment to
                    // answer the discovery it sends back.
                    if let own = ownStatus {
                        let reply = [UInt8](own)
                        _ = withUnsafePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, reply, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                        answered += 1
                        continue
                    }
                    report.note = "sent=\(sent) received=\(datagrams) bound=\(boundPort)"
                    return report
                }
                if others.count < 3 { others.append("\(source):\(n)") }
            }
        }
        report.note = "sent=\(sent)/\(max(1, attempts)) send-errno=\(sendErrno) received=\(datagrams) answered=\(answered) bound=\(boundPort)" +
            (others.isEmpty ? "" : " other=\(others.joined(separator: ","))")
        return report
    }

    // MARK: RequestPeerContentServer

    /// What Steam answers when it opened a PC's content server.
    struct PeerServer: Sendable, Equatable {
        var port: UInt16 = 0
        var depots: Set<UInt32> = []
        var accessToken: UInt64 = 0
    }

    /// CContentServerDirectory_RequestPeerContentServer_Request.
    static func peerServerRequest(localClientID: UInt64, steamID: UInt64, serverClientID: UInt64,
                                  appID: UInt32, buildID: UInt32) -> Data {
        var body = ProtobufEncoder()
        body.writeUInt64(fieldNumber: 1, value: localClientID)    // remote_client_id
        body.writeUInt64(fieldNumber: 2, value: steamID)          // steamid
        body.writeUInt64(fieldNumber: 3, value: serverClientID)   // server_remote_client_id
        body.writeUInt32(fieldNumber: 4, value: appID)            // app_id
        body.writeUInt32(fieldNumber: 5, value: buildID)          // current_build_id
        return body.data
    }

    /// CContentServerDirectory_RequestPeerContentServer_Response. A port of 0
    /// or no token means Steam did not open the PC's content server.
    static func parsePeerServerResponse(_ data: Data) throws -> PeerServer {
        var server = PeerServer()
        var decoder = ProtobufDecoder(data)
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): server.port = UInt16(truncatingIfNeeded: try decoder.readVarint())
            case (2, .varint): server.depots.insert(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case (2, .lengthDelimited):   // packed repeated uint32
                var packed = ProtobufDecoder(try decoder.readBytes())
                while !packed.isAtEnd { server.depots.insert(UInt32(truncatingIfNeeded: try packed.readVarint())) }
            case (3, .varint): server.accessToken = try decoder.readVarint()
            case (3, .fixed64): server.accessToken = try decoder.readFixed64()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return server
    }

    /// CContentServerDirectory_GetPeerContentInfo_Request.
    static func peerContentInfoRequest(localClientID: UInt64, steamID: UInt64, serverClientID: UInt64) -> Data {
        var body = ProtobufEncoder()
        body.writeUInt64(fieldNumber: 1, value: localClientID)    // remote_client_id
        body.writeUInt64(fieldNumber: 2, value: steamID)          // steamid
        body.writeUInt64(fieldNumber: 3, value: serverClientID)   // server_remote_client_id
        return body.data
    }

    /// CContentServerDirectory_GetPeerContentInfo_Response: the apps the PC
    /// serves and its public IP.
    static func parsePeerContentInfo(_ data: Data) throws -> (apps: Set<UInt32>, publicIP: String) {
        var apps = Set<UInt32>(), ip = ""
        var decoder = ProtobufDecoder(data)
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): apps.insert(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case (1, .lengthDelimited):
                var packed = ProtobufDecoder(try decoder.readBytes())
                while !packed.isAtEnd { apps.insert(UInt32(truncatingIfNeeded: try packed.readVarint())) }
            case (2, .lengthDelimited): ip = try decoder.readString()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return (apps, ip)
    }

    /// The sender's client ID and packet in a CRemoteClient_SteamBroadcast_Notification
    /// Steam pushed to this device (RemoteClientSteamClient.NotifySteamBroadcastPacket).
    static func relayedPacket(_ body: Data) -> (clientID: UInt64, payload: Data)? {
        var clientID: UInt64 = 0, payload = Data()
        var decoder = ProtobufDecoder(body)
        fields: while let tag = try? decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (2, .fixed64): clientID = (try? decoder.readFixed64()) ?? 0
            case (3, .lengthDelimited): payload = (try? decoder.readBytes()) ?? Data()
            default: if (try? decoder.skip(wireType: tag.wireType)) == nil { break fields }
            }
        }
        return payload.isEmpty ? nil : (clientID, payload)
    }

    /// CRemoteClient_SteamBroadcast_Notification: a discovery-format packet
    /// Steam relays to the account's other clients.
    static func steamBroadcast(steamID: UInt64, clientID: UInt64, payload: Data) -> Data {
        var body = ProtobufEncoder()
        body.writeFixed64(fieldNumber: 1, value: steamID)
        body.writeFixed64(fieldNumber: 2, value: clientID)
        body.writeBytes(fieldNumber: 3, value: payload)
        return body.data
    }

    // MARK: RemoteClient service

    /// CRemoteClient_Online_Notification: this device as a remote client of `steamID`.
    static func onlineNotification(steamID: UInt64, localClientID: UInt64, name: String) -> Data {
        var details = ProtobufEncoder()
        details.writeString(fieldNumber: 1, value: name)        // device_friendly_name
        details.writeInt32(fieldNumber: 2, value: -102)         // os_type: macOS, as at logon
        details.writeUInt32(fieldNumber: 3, value: 1)           // gaming_device_type: standard PC
        var body = ProtobufEncoder()
        body.writeFixed64(fieldNumber: 1, value: steamID)       // steamid
        body.writeFixed64(fieldNumber: 2, value: localClientID) // remote_client_id
        body.writeSubmessage(fieldNumber: 3, value: details.data)
        return body.data
    }

    struct RecentClient: Sendable, Equatable {
        var clientID: UInt64 = 0
        var name = ""
        var online = false
    }

    /// CRemoteClient_GetRecentClients_Response.
    static func parseRecentClients(_ data: Data) throws -> [RecentClient] {
        var clients: [RecentClient] = []
        var decoder = ProtobufDecoder(data)
        while let tag = try decoder.readTag() {
            guard tag.fieldNumber == 1, tag.wireType == .lengthDelimited else { try decoder.skip(wireType: tag.wireType); continue }
            var client = RecentClient()
            var c = ProtobufDecoder(try decoder.readBytes())
            while let t = try c.readTag() {
                switch (t.fieldNumber, t.wireType) {
                case (1, .fixed64): client.clientID = try c.readFixed64()
                case (1, .varint): client.clientID = try c.readVarint()
                case (2, .lengthDelimited):
                    var d = ProtobufDecoder(try c.readBytes())
                    while let dt = try d.readTag() {
                        if dt.fieldNumber == 1, dt.wireType == .lengthDelimited { client.name = try d.readString() }
                        else { try d.skip(wireType: dt.wireType) }
                    }
                case (8, .varint): client.online = try c.readVarint() != 0
                default: try c.skip(wireType: t.wireType)
                }
            }
            clients.append(client)
        }
        return clients
    }

    // MARK: TCP framing

    /// One Steam TCP frame around a protobuf message with an empty header.
    static func frame(eMsg: UInt32, body: Data) -> Data {
        var payload = Data()
        append32(&payload, eMsg | 0x8000_0000)
        append32(&payload, 0)
        payload.append(body)
        var out = Data()
        append32(&out, UInt32(payload.count))
        out.append(contentsOf: tcpMagic)
        out.append(payload)
        return out
    }

    static func chunkRequest(appID: UInt32, depotID: UInt32, sha: Data, accessToken: UInt64) -> Data {
        var body = ProtobufEncoder()
        body.writeUInt32(fieldNumber: 1, value: appID)
        body.writeUInt32(fieldNumber: 2, value: depotID)
        body.writeBytes(fieldNumber: 3, value: sha)
        body.writeUInt64(fieldNumber: 4, value: accessToken)
        return frame(eMsg: peerChunkRequest, body: body.data)
    }

    struct ChunkResponse: Sendable {
        var result: UInt32 = 0
        var depotID: UInt32 = 0
        var sha = Data()
        var encrypted = false
        var compressed = false
        var data = Data()
    }

    /// The body of a k_EMsgClientPeerChunkResponse (after the frame and the message header).
    static func parseChunkResponse(_ body: Data) throws -> ChunkResponse {
        var response = ChunkResponse()
        var decoder = ProtobufDecoder(body)
        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: response.result = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 3: response.depotID = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 4: response.sha = try decoder.readBytes()
            case 5: response.encrypted = try decoder.readVarint() != 0
            case 6: response.compressed = try decoder.readVarint() != 0
            case 7: response.data = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return response
    }

    // MARK: Helpers

    static func append32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval()
        tv.tv_sec = Int(seconds)
        tv.tv_usec = .init((seconds - floor(seconds)) * 1_000_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// One PC's content server for one app, as RequestPeerContentServer opened it.
/// Requests go one at a time over a single TCP connection on a private serial
/// queue, so the download tasks never block a thread of their own. After a few
/// failures in a row the source stops being used and every chunk goes to the
/// content servers.
final class SteamPeerChunkSource: @unchecked Sendable {
    let host: String
    let port: UInt16
    let appID: UInt32
    let depots: Set<UInt32>
    private let accessToken: UInt64
    /// Connects and sends, in request order.
    private let writeQueue = DispatchQueue(label: "madeira.steam.lan-peer")
    private let lock = NSLock()
    private var connection: Connection?
    private var failuresInARow = 0
    private var disabled = false
    private(set) var chunks = 0
    private(set) var bytes: UInt64 = 0
    private(set) var failures = 0
    static let maximumFailuresInARow = 4
    /// Seconds without any answer while requests are waiting before the
    /// connection counts as broken.
    static let answerTimeout: TimeInterval = 15
    /// Seconds to wait for the PC to accept the TCP connection.
    static let connectTimeout: TimeInterval = 4

    /// One TCP connection to the PC: the requests waiting on it, by chunk SHA-1.
    private final class Connection {
        let fd: Int32
        var waiting: [Data: [CheckedContinuation<SteamLANPeer.ChunkResponse, Error>]] = [:]
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    /// The PC's host name, for the download's status.
    let name: String

    init(host: String, port: UInt16, appID: UInt32, depots: Set<UInt32>, accessToken: UInt64, name: String = "") {
        self.host = host; self.port = port; self.appID = appID; self.depots = depots; self.accessToken = accessToken
        self.name = name.isEmpty ? host : name
    }

    var usable: Bool { lock.lock(); defer { lock.unlock() }; return !disabled }

    func serves(_ depotID: UInt32) -> Bool { usable && (depots.isEmpty || depots.contains(depotID)) }

    /// The chunk's bytes as the PC sends them (see `ChunkResponse.encrypted` / `.compressed`).
    /// Callers may wait on several at once: the requests share one connection.
    func fetch(depotID: UInt32, sha: Data) async throws -> SteamLANPeer.ChunkResponse {
        guard usable else { throw SteamError.chunkDownloadFailed("The PC on this network is no longer used.") }
        let request = [UInt8](SteamLANPeer.chunkRequest(appID: appID, depotID: depotID, sha: sha, accessToken: accessToken))
        return try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                guard self.usable else {
                    continuation.resume(throwing: SteamError.chunkDownloadFailed("The PC on this network is no longer used."))
                    return
                }
                let link: Connection
                do { link = try self.currentConnection() } catch {
                    // The PC cannot be reached at all: every other request goes
                    // to Steam's servers instead of trying again.
                    self.lock.lock(); self.disabled = true; self.lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                self.lock.lock()
                let open = !link.closed
                if open { link.waiting[sha, default: []].append(continuation) }
                self.lock.unlock()
                guard open else {
                    continuation.resume(throwing: SteamError.chunkDownloadFailed("The PC closed the connection."))
                    return
                }
                do { try Self.sendAll(link.fd, request) } catch { self.fail(link, error) }
            }
        }
    }

    func recordSuccess(bytes count: Int) {
        lock.lock(); chunks += 1; bytes += UInt64(count); failuresInARow = 0; lock.unlock()
    }

    /// Returns true when this failure turned the source off.
    @discardableResult func recordFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        failures += 1; failuresInARow += 1
        if !disabled, failuresInARow >= Self.maximumFailuresInARow { disabled = true; return true }
        return false
    }

    func close() {
        writeQueue.sync {
            lock.lock(); let link = connection; lock.unlock()
            if let link { fail(link, SteamError.chunkDownloadFailed("The download from the PC ended.")) }
        }
    }

    // MARK: Connection

    /// On writeQueue: the open connection, connecting (and starting its reader) when there is none.
    private func currentConnection() throws -> Connection {
        lock.lock()
        if let link = connection, !link.closed { lock.unlock(); return link }
        lock.unlock()
        let link = Connection(fd: try connect())
        lock.lock(); connection = link; lock.unlock()
        let reader = Thread { [weak self] in self?.read(link) }
        reader.name = "madeira.steam.lan-peer.read"
        reader.start()
        return link
    }

    /// Ends `link` and fails every request waiting on it.
    private func fail(_ link: Connection, _ error: Error) {
        lock.lock()
        let waiting = link.closed ? [:] : link.waiting
        if !link.closed {
            link.closed = true
            link.waiting = [:]
            shutdown(link.fd, Int32(SHUT_RDWR))
        }
        if connection === link { connection = nil }
        lock.unlock()
        for continuation in waiting.values.joined() { continuation.resume(throwing: error) }
    }

    /// The reader thread: answers in any order, each to the oldest request for its SHA-1.
    private func read(_ link: Connection) {
        var idleSince = Date()
        defer { Darwin_or_Glibc_close(link.fd) }
        while true {
            do {
                guard let header = try Self.receive(link.fd, 8, allowIdle: true) else {
                    // Receive timeout with nothing read: fine while nothing waits.
                    lock.lock(); let closed = link.closed, idle = link.waiting.isEmpty; lock.unlock()
                    if closed { return }
                    if idle { idleSince = Date(); continue }
                    if Date().timeIntervalSince(idleSince) < Self.answerTimeout { continue }
                    throw SteamError.chunkDownloadFailed("The PC stopped answering.")
                }
                idleSince = Date()
                guard Array(header[4..<8]) == SteamLANPeer.tcpMagic else { throw SteamError.chunkDownloadFailed("Unexpected data from the PC.") }
                let length = Int(SteamLANPeer.read32(header, 0))
                guard length >= 8, length <= ContentDecryptor.maximumChunkBytes + 4096 else {
                    throw SteamError.chunkDownloadFailed("Unexpected message size from the PC.")
                }
                guard let payload = try Self.receive(link.fd, length, allowIdle: false) else { continue }
                let eMsg = SteamLANPeer.read32(payload, 0) & 0x7FFF_FFFF
                let headerLength = Int(SteamLANPeer.read32(payload, 4))
                guard 8 + headerLength <= payload.count else { throw SteamError.chunkDownloadFailed("Unexpected message from the PC.") }
                guard eMsg == SteamLANPeer.peerChunkResponse else { continue }
                let response = try SteamLANPeer.parseChunkResponse(Data(payload[(8 + headerLength)...]))
                lock.lock()
                var continuation: CheckedContinuation<SteamLANPeer.ChunkResponse, Error>?
                if var queue = link.waiting[response.sha], !queue.isEmpty {
                    continuation = queue.removeFirst()
                    link.waiting[response.sha] = queue.isEmpty ? nil : queue
                }
                lock.unlock()
                continuation?.resume(returning: response)  // none: an answer to an abandoned request
            } catch {
                fail(link, error)
                return
            }
        }
    }

    private func connect() throws -> Int32 {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw SteamError.chunkDownloadFailed("Bad PC address.") }
        #if canImport(Darwin)
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        #else
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
        #endif
        guard s >= 0 else { throw SteamError.chunkDownloadFailed("No socket (errno \(errno)).") }
        var yes: Int32 = 1
        setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var buffer: Int32 = 4 * 1024 * 1024
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        SteamLANPeer.setTimeout(s, 2)
        // Non-blocking connect with a short limit: a firewall that drops the
        // SYN would otherwise hold every waiting request for the system's
        // TCP connect timeout (over a minute).
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc_or_Darwin_connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var code = rc == 0 ? 0 : errno
        if rc != 0, code == EINPROGRESS {
            var waiter = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            rc = poll(&waiter, 1, Int32(Self.connectTimeout * 1000))
            if rc == 1 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &length)
                code = error
            } else {
                code = ETIMEDOUT
            }
        }
        guard code == 0 else {
            Darwin_or_Glibc_close(s)
            throw SteamError.chunkDownloadFailed(code == ETIMEDOUT
                ? "The PC did not accept the connection (a firewall on the PC?)."
                : "Cannot reach the PC (errno \(code)).")
        }
        _ = fcntl(s, F_SETFL, flags)
        return s
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                #if canImport(Darwin)
                return send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                #else
                return send(fd, raw.baseAddress! + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #endif
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            guard n > 0 else { throw SteamError.chunkDownloadFailed("The PC closed the connection (errno \(errno)).") }
            sent += n
        }
    }

    /// `count` bytes, or nil when `allowIdle` and the receive timeout passed before any arrived.
    private static func receive(_ fd: Int32, _ count: Int, allowIdle: Bool) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        var stalls = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                if got == 0, allowIdle { return nil }
                stalls += 1
                // Inside a message: the 2 s receive timeout, up to answerTimeout in all.
                if Double(stalls) * 2 >= answerTimeout { throw SteamError.chunkDownloadFailed("The PC stopped mid-answer.") }
                continue
            }
            guard n > 0 else { throw SteamError.chunkDownloadFailed("The PC closed the connection (errno \(errno)).") }
            got += n
        }
        return buffer
    }
}

// `connect` and `close` are also method names in this file; these reach the C functions.
@inline(__always) private func Glibc_or_Darwin_connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(fd, address, length)
}
@inline(__always) private func Darwin_or_Glibc_close(_ fd: Int32) { _ = close(fd) }
