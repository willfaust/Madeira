// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). The protobuf
// helpers and the IAuthenticationService messages are what sign-in uses; the
// CM logon, license, product-info (PICS), depot-key and service-call messages
// were added for the owned library and downloads (docs/STEAM_LIBRARY.md).
// Field numbers are Valve's, from its public protocol definitions.

import Foundation

// MARK: - Steam Protobuf Message Stubs
//
// These are hand-written Swift structs that mirror the essential Steam protobuf messages.
// They implement manual protobuf encoding/decoding (field tag + wire type + value)
// without requiring the swift-protobuf dependency.
//
// Wire types: 0=varint, 1=64-bit, 2=length-delimited, 5=32-bit

// MARK: - Protobuf Encoding Helpers

enum ProtoWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct ProtobufEncoder {
    private(set) var data = Data()

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func writeTag(fieldNumber: UInt32, wireType: ProtoWireType) {
        writeVarint(UInt64(fieldNumber << 3 | UInt32(wireType.rawValue)))
    }

    mutating func writeString(fieldNumber: UInt32, value: String) {
        guard !value.isEmpty else { return }
        let bytes = Data(value.utf8)
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeBytes(fieldNumber: UInt32, value: Data) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeUInt32(fieldNumber: UInt32, value: UInt32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeUInt64(fieldNumber: UInt32, value: UInt64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeInt32(fieldNumber: UInt32, value: Int32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    /// Write an int32 field unconditionally, even when value is 0.
    mutating func writeInt32Always(fieldNumber: UInt32, value: Int32) {
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func writeInt64(fieldNumber: UInt32, value: Int64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: value))
    }

    mutating func writeBool(fieldNumber: UInt32, value: Bool) {
        guard value else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(1)
    }

    mutating func writeFixed32(fieldNumber: UInt32, value: UInt32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .fixed32)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    mutating func writeFixed64(fieldNumber: UInt32, value: UInt64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .fixed64)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    /// Write a fixed64 field unconditionally, even when value is 0.
    /// The message header's steamid must always be present.
    mutating func writeFixed64Always(fieldNumber: UInt32, value: UInt64) {
        writeTag(fieldNumber: fieldNumber, wireType: .fixed64)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    mutating func writeSubmessage(fieldNumber: UInt32, value: Data) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }
}

struct ProtobufDecoder {
    let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw SteamError.protobufError("Varint too long")
            }
        }
        throw SteamError.protobufError("Unexpected end of data reading varint")
    }

    mutating func readTag() throws -> (fieldNumber: UInt32, wireType: ProtoWireType)? {
        guard !isAtEnd else { return nil }
        let tag = try readVarint()
        let wireTypeRaw = UInt8(tag & 0x7)
        guard let wireType = ProtoWireType(rawValue: wireTypeRaw) else {
            throw SteamError.protobufError("Unknown wire type: \(wireTypeRaw)")
        }
        return (fieldNumber: UInt32(tag >> 3), wireType: wireType)
    }

    /// A length prefix, checked against the bytes that remain. Lengths come
    /// from the network, so an oversized value must throw, not trap.
    mutating func readLength() throws -> Int {
        let length = try readVarint()
        guard length <= UInt64(data.count - offset) else {
            throw SteamError.protobufError("Length past end of data")
        }
        return Int(length)
    }

    mutating func readBytes() throws -> Data {
        let length = try readLength()
        guard offset + length <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading bytes")
        }
        let bytes = data[offset..<offset + length]
        offset += length
        return Data(bytes)
    }

    mutating func readString() throws -> String {
        let bytes = try readBytes()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw SteamError.protobufError("Invalid UTF-8 string")
        }
        return str
    }

    mutating func readFixed32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading fixed32")
        }
        let value = data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading fixed64")
        }
        let value = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func skip(wireType: ProtoWireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            offset += 8
        case .lengthDelimited:
            offset += try readLength()
        case .fixed32:
            offset += 4
        }
        guard offset <= data.count else {
            throw SteamError.protobufError("Skip went past end of data")
        }
    }
}

// MARK: - CMsgProtoBufHeader

/// Header included with every protobuf-encoded Steam message
struct CMsgProtoBufHeader {
    var steamid: UInt64 = 0
    var clientSessionid: Int32 = 0
    var jobidSource: UInt64 = UInt64.max
    var jobidTarget: UInt64 = UInt64.max
    var targetJobName: String = ""
    var eresult: Int32 = 0

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Always write steamid and client_sessionid — CM servers silently drop
        // messages with an empty protobuf header (all fields at default = nothing on wire).
        encoder.writeFixed64Always(fieldNumber: 1, value: steamid)
        encoder.writeInt32Always(fieldNumber: 2, value: clientSessionid)
        // Field numbers from Valve's steammessages_base.proto:
        // jobid_source=10, jobid_target=11, target_job_name=12, eresult=13
        if jobidSource != UInt64.max {
            encoder.writeFixed64(fieldNumber: 10, value: jobidSource)
        }
        if jobidTarget != UInt64.max {
            encoder.writeFixed64(fieldNumber: 11, value: jobidTarget)
        }
        encoder.writeString(fieldNumber: 12, value: targetJobName)
        encoder.writeInt32(fieldNumber: 13, value: eresult)
        return encoder.data
    }

    static func deserialize(from data: Data) throws -> CMsgProtoBufHeader {
        var decoder = ProtobufDecoder(data)
        var header = CMsgProtoBufHeader()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: header.steamid = try decoder.readFixed64()
            case 2: header.clientSessionid = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 10: header.jobidSource = try decoder.readFixed64()
            case 11: header.jobidTarget = try decoder.readFixed64()
            case 12: header.targetJobName = try decoder.readString()
            case 13: header.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }

        return header
    }
}

// MARK: - Authentication Messages

/// Request RSA public key for password encryption
struct CAuthentication_GetPasswordRSAPublicKey_Request {
    var accountName: String = ""

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: accountName)
        return encoder.data
    }
}

struct CAuthentication_GetPasswordRSAPublicKey_Response {
    var publicKeyMod: String = ""
    var publicKeyExp: String = ""
    var timestamp: UInt64 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.publicKeyMod = try decoder.readString()
            case 2: msg.publicKeyExp = try decoder.readString()
            case 3: msg.timestamp = try decoder.readVarint()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Begin credential-based auth session
struct CAuthentication_BeginAuthSessionViaCredentials_Request {
    var accountName: String = ""
    var encryptedPassword: String = ""  // Base64 encoded RSA-encrypted password
    var encryptionTimestamp: UInt64 = 0
    var platformType: UInt32 = 1       // k_EAuthTokenPlatformType_SteamClient = 1
    var persistence: UInt32 = 1        // k_ESessionPersistence_Persistent = 1
    var deviceFriendlyName: String = ""
    var websiteId: String = "Client"

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Field numbers from steammessages_auth.steamclient.proto:
        //   1 device_friendly_name, 2 account_name, 3 encrypted_password,
        //   4 encryption_timestamp, 6 platform_type, 7 persistence,
        //   8 website_id, 9 device_details.
        // An earlier version of this port sent the account name as field 1 and the
        // encrypted password as field 2, so Steam read the password blob as the
        // account name and every typed sign-in failed with InvalidPassword /
        // AccountNotFound ("account name or password is incorrect").
        encoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        encoder.writeString(fieldNumber: 2, value: accountName)
        encoder.writeString(fieldNumber: 3, value: encryptedPassword)
        encoder.writeUInt64(fieldNumber: 4, value: encryptionTimestamp)
        encoder.writeUInt32(fieldNumber: 6, value: platformType)
        encoder.writeUInt32(fieldNumber: 7, value: persistence)
        encoder.writeString(fieldNumber: 8, value: websiteId)
        // CAuthentication_DeviceDetails: 1 device_friendly_name, 2 platform_type.
        var deviceEncoder = ProtobufEncoder()
        deviceEncoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        deviceEncoder.writeUInt32(fieldNumber: 2, value: platformType)
        encoder.writeSubmessage(fieldNumber: 9, value: deviceEncoder.data)
        return encoder.data
    }
}

struct CAuthentication_BeginAuthSessionViaCredentials_Response {
    var clientID: UInt64 = 0
    var requestID: Data = Data()
    var interval: Float = 5.0
    var allowedConfirmations: [AllowedConfirmation] = []
    var steamid: UInt64 = 0

    struct AllowedConfirmation {
        var confirmationType: UInt32 = 0  // k_EAuthSessionGuardType
        var associatedMessage: String = ""
    }

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.clientID = try decoder.readVarint()
            case 2: msg.requestID = try decoder.readBytes()
            case 3:
                let bits = UInt32(try decoder.readFixed32())
                msg.interval = Float(bitPattern: bits)
            case 4:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var confirmation = AllowedConfirmation()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: confirmation.confirmationType = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: confirmation.associatedMessage = try subDecoder.readString()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.allowedConfirmations.append(confirmation)
            // steamid: accept either encoding rather than trust one.
            case 5: msg.steamid = try (tag.wireType == .fixed64 ? decoder.readFixed64() : decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Begin QR auth session
struct CAuthentication_BeginAuthSessionViaQR_Request {
    var deviceFriendlyName: String = ""
    var platformType: UInt32 = 1

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        encoder.writeUInt32(fieldNumber: 2, value: platformType)
        return encoder.data
    }
}

struct CAuthentication_BeginAuthSessionViaQR_Response {
    var clientID: UInt64 = 0
    var challengeURL: String = ""
    var requestID: Data = Data()
    var interval: Float = 5.0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.clientID = try decoder.readVarint()
            case 2: msg.challengeURL = try decoder.readString()
            case 3: msg.requestID = try decoder.readBytes()
            case 4:
                let bits = try decoder.readFixed32()
                msg.interval = Float(bitPattern: bits)
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Update auth session with Steam Guard code
struct CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request {
    var clientID: UInt64 = 0
    var steamid: UInt64 = 0
    var code: String = ""
    var codeType: UInt32 = 0  // k_EAuthSessionGuardType

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt64(fieldNumber: 1, value: clientID)
        encoder.writeFixed64(fieldNumber: 2, value: steamid)   // fixed64 steamid = 2 in the proto
        encoder.writeString(fieldNumber: 3, value: code)
        encoder.writeUInt32(fieldNumber: 4, value: codeType)
        return encoder.data
    }
}

/// Poll for auth session status
struct CAuthentication_PollAuthSessionStatus_Request {
    var clientID: UInt64 = 0
    var requestID: Data = Data()

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt64(fieldNumber: 1, value: clientID)
        encoder.writeBytes(fieldNumber: 2, value: requestID)
        return encoder.data
    }
}

struct CAuthentication_PollAuthSessionStatus_Response {
    var newClientID: UInt64 = 0
    var newChallengeURL: String = ""
    var refreshToken: String = ""
    var accessToken: String = ""
    var hadRemoteInteraction: Bool = false
    var accountName: String = ""
    var newGuardData: String = ""

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.newClientID = try decoder.readVarint()
            case 2: msg.newChallengeURL = try decoder.readString()
            case 3: msg.refreshToken = try decoder.readString()
            case 4: msg.accessToken = try decoder.readString()
            case 5: msg.hadRemoteInteraction = try decoder.readVarint() != 0
            case 6: msg.accountName = try decoder.readString()
            case 7: msg.newGuardData = try decoder.readString()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Client Hello

/// Sent immediately after WebSocket connection to initiate the Steam3 handshake.
/// Without this, the CM server will reject messages and close the connection.
struct CMsgClientHello {
    var protocolVersion: UInt32 = 65580

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: protocolVersion)
        return encoder.data
    }
}

// MARK: - Client Login Messages

/// Client logon request
struct CMsgClientLogon {
    var accountName: String = ""
    var accessToken: String = ""
    var protocolVersion: UInt32 = 65580
    var cellID: UInt32 = 0
    var clientOSType: Int32 = -102  // MacOS
    var clientLanguage: String = "english"
    var shouldRememberPassword: Bool = true
    var machineName: String = ""
    var machineID: Data = Data()
    var supportsRateLimitResponse: Bool = true
    var clientPackageVersion: UInt32 = 1771

    /// The machine's LAN IPv4 address in host byte order (for obfuscation),
    /// and its interface. Wi-Fi/Ethernet (en*) first: on iOS the cellular
    /// interface (pdp_ip*) usually comes first in the list, and Steam uses
    /// this address to tell which of an account's devices share a network.
    /// getifaddrs works on both macOS and iOS — Host.current() doesn't exist on iOS.
    static func localIPv4() -> (ip: UInt32, interface: String) {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return (0, "") }
        defer { freeifaddrs(addrList) }
        var best: (ip: UInt32, interface: String, rank: Int)?
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let ip = UInt32(bigEndian: raw)  // same byte order as a<<24|b<<16|c<<8|d
            if ip >> 16 == 0xA9FE { continue }  // 169.254/16, link-local
            let rank = name == "en0" ? 0 : name.hasPrefix("en") ? 1 :
                (name.hasPrefix("pdp_ip") || name.hasPrefix("utun") || name.hasPrefix("ipsec")) ? 3 : 2
            if best == nil || rank < best!.rank { best = (ip, name, rank) }
        }
        return best.map { ($0.ip, $0.interface) } ?? (0, "")
    }

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Field numbers from Valve's steammessages_clientserver_login.proto
        encoder.writeUInt32(fieldNumber: 1, value: protocolVersion)             // protocol_version = 1
        // obfuscated_private_ip (field 11) — CMsgIPAddress sub-message with local IPv4 XOR'd with mask.
        // Valve's own client always sends this; without it some CM servers silently ignore the logon.
        // NOTE: field 2 is deprecated_obfustucated_private_ip (uint32), field 11 is the correct CMsgIPAddress.
        let localIP = CMsgClientLogon.localIPv4().ip
        let obfuscatedIP = localIP ^ 0xBAADF00D
        var ipEncoder = ProtobufEncoder()
        ipEncoder.writeFixed32(fieldNumber: 1, value: obfuscatedIP)
        encoder.writeSubmessage(fieldNumber: 11, value: ipEncoder.data)         // obfuscated_private_ip = 11
        if cellID != 0 {
            encoder.writeUInt32(fieldNumber: 3, value: cellID)                  // cell_id = 3
        }
        encoder.writeUInt32(fieldNumber: 5, value: clientPackageVersion)        // client_package_version = 5
        encoder.writeString(fieldNumber: 6, value: clientLanguage)              // client_language = 6
        // client_os_type = 7 (uint32 in proto; Steam uses negative values for macOS e.g. -102)
        encoder.writeUInt32(fieldNumber: 7, value: UInt32(bitPattern: clientOSType)) // client_os_type = 7
        encoder.writeBool(fieldNumber: 8, value: shouldRememberPassword)        // should_remember_password = 8
        encoder.writeBytes(fieldNumber: 30, value: machineID)                   // machine_id = 30
        encoder.writeString(fieldNumber: 50, value: accountName)                // account_name = 50
        encoder.writeString(fieldNumber: 96, value: machineName)                // machine_name = 96
        encoder.writeBool(fieldNumber: 102, value: supportsRateLimitResponse)   // supports_rate_limit_response = 102
        encoder.writeString(fieldNumber: 108, value: accessToken)               // access_token = 108
        return encoder.data
    }
}

/// Client logon response
struct CMsgClientLogonResponse {
    var eresult: Int32 = 0
    var heartbeatSeconds: Int32 = 0
    var clientSuppliedSteamID: UInt64 = 0
    var vanityURL: String = ""
    var cellID: UInt32 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())       // eresult = 1
            case 3: msg.heartbeatSeconds = Int32(truncatingIfNeeded: try decoder.readVarint()) // heartbeat_seconds = 3
            case 7: msg.cellID = UInt32(truncatingIfNeeded: try decoder.readVarint())                           // cell_id = 7
            case 14: msg.vanityURL = try decoder.readString()                               // vanity_url = 14
            case 20: msg.clientSuppliedSteamID = try decoder.readFixed64()                  // client_supplied_steamid = 20
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - License / Ownership Messages

struct CMsgClientLicenseList {
    struct License {
        var packageID: UInt32 = 0
        var timeCreated: UInt32 = 0
        var timeNextProcess: UInt32 = 0
        var minuteLimit: Int32 = 0
        var minutesUsed: Int32 = 0
        var paymentMethod: UInt32 = 0
        var flags: UInt32 = 0
        var purchaseCountryCode: String = ""
        var licenseType: UInt32 = 0
        var territoryCode: Int32 = 0
        var ownerID: UInt32 = 0
    }

    var eresult: Int32 = 0
    var licenses: [License] = []

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 2:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var license = License()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: license.packageID = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: license.timeCreated = try subDecoder.readFixed32()      // fixed32 on the wire, not varint
                    case 3: license.timeNextProcess = try subDecoder.readFixed32()  // fixed32 on the wire, not varint
                    case 4: license.minuteLimit = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 5: license.minutesUsed = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 6: license.paymentMethod = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 7: license.flags = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 8: license.purchaseCountryCode = try subDecoder.readString()
                    case 9: license.licenseType = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 10: license.territoryCode = Int32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 14: license.ownerID = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.licenses.append(license)
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - PICS Messages

struct CMsgClientPICSProductInfoRequest {
    struct AppInfo {
        var appid: UInt32 = 0
        var accessToken: UInt64 = 0
    }
    struct PackageInfo {
        var packageid: UInt32 = 0
        var accessToken: UInt64 = 0
    }

    var apps: [AppInfo] = []
    var packages: [PackageInfo] = []
    var metaDataOnly: Bool = false

    func serialize() -> Data {
        // Field numbers per steammessages_clientserver_appinfo.proto:
        // packages = 1, apps = 2; access_token is uint64 (varint).
        var encoder = ProtobufEncoder()
        for pkg in packages {
            var subEncoder = ProtobufEncoder()
            subEncoder.writeUInt32(fieldNumber: 1, value: pkg.packageid)
            subEncoder.writeUInt64(fieldNumber: 2, value: pkg.accessToken)
            encoder.writeSubmessage(fieldNumber: 1, value: subEncoder.data)
        }
        for app in apps {
            var subEncoder = ProtobufEncoder()
            subEncoder.writeUInt32(fieldNumber: 1, value: app.appid)
            subEncoder.writeUInt64(fieldNumber: 2, value: app.accessToken)
            encoder.writeSubmessage(fieldNumber: 2, value: subEncoder.data)
        }
        encoder.writeBool(fieldNumber: 3, value: metaDataOnly)
        return encoder.data
    }
}

struct CMsgClientPICSProductInfoResponse {
    struct AppInfo {
        var appid: UInt32 = 0
        var changeNumber: UInt32 = 0
        /// Field 3, set when the request lacked a valid access token.
        var missingToken = false
        var buffer: Data = Data()  // VDF binary format app info
    }
    struct PackageInfo {
        var packageid: UInt32 = 0
        var changeNumber: UInt32 = 0
        var buffer: Data = Data()
    }

    var apps: [AppInfo] = []
    var packages: [PackageInfo] = []
    var unknownApps: [UInt32] = []
    var unknownPackages: [UInt32] = []
    // Field 6: how many more PICSProductInfoResponse messages are coming for this job.
    // When 0, all parts have been received.
    var pendingResponseCount: Int32 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var app = AppInfo()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: app.appid = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: app.changeNumber = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 3 where subTag.wireType == .varint: app.missingToken = try subDecoder.readVarint() != 0
                    case 5: app.buffer = try subDecoder.readBytes()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.apps.append(app)
            case 2: msg.unknownApps.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 3:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var pkg = PackageInfo()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: pkg.packageid = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: pkg.changeNumber = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 5: pkg.buffer = try subDecoder.readBytes()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.packages.append(pkg)
            case 4: msg.unknownPackages.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 6: msg.pendingResponseCount = Int32(truncatingIfNeeded: try decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Depot Messages

struct CMsgClientGetDepotDecryptionKey {
    var depotID: UInt32 = 0
    var appID: UInt32 = 0

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: depotID)
        encoder.writeUInt32(fieldNumber: 2, value: appID)
        return encoder.data
    }
}

struct CMsgClientGetDepotDecryptionKeyResponse {
    var eresult: Int32 = 0
    var depotID: UInt32 = 0
    var depotEncryptionKey: Data = Data()

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.eresult = Int32(truncatingIfNeeded: try decoder.readVarint())
            case 2: msg.depotID = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 3: msg.depotEncryptionKey = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Service Method Wrapper

/// Wraps a service method call for sending via EMsg.serviceMethodCallFromClient
struct CMsgClientServiceMethod {
    var methodName: String = ""
    var serializedMethod: Data = Data()
    var isNotification: Bool = false

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: methodName)
        encoder.writeBytes(fieldNumber: 2, value: serializedMethod)
        encoder.writeBool(fieldNumber: 3, value: isNotification)
        return encoder.data
    }
}

struct CMsgClientServiceMethodResponse {
    var methodName: String = ""
    var serializedMethodResponse: Data = Data()

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.methodName = try decoder.readString()
            case 2: msg.serializedMethodResponse = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - Multi Message (for bundled responses)

struct CMsgMulti {
    var sizeUnzipped: UInt32 = 0
    var messageBody: Data = Data()

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.sizeUnzipped = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 2: msg.messageBody = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

// MARK: - PICS Access Token Messages

struct CMsgClientPICSAccessTokenRequest {
    var appids: [UInt32] = []
    var packageids: [UInt32] = []

    func serialize() -> Data {
        // Field numbers per steammessages_clientserver_appinfo.proto:
        // packageids = 1, appids = 2.
        var encoder = ProtobufEncoder()
        for pkgid in packageids {
            encoder.writeUInt32(fieldNumber: 1, value: pkgid)
        }
        for appid in appids {
            encoder.writeUInt32(fieldNumber: 2, value: appid)
        }
        return encoder.data
    }
}

struct CMsgClientPICSAccessTokenResponse {
    struct AppToken {
        var appid: UInt32 = 0
        var accessToken: UInt64 = 0
    }
    struct PackageToken {
        var packageid: UInt32 = 0
        var accessToken: UInt64 = 0
    }

    var appAccessTokens: [AppToken] = []
    var packageAccessTokens: [PackageToken] = []
    var appAccessTokensDenied: [UInt32] = []
    var packageAccessTokensDenied: [UInt32] = []

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        // Field numbers per steammessages_clientserver_appinfo.proto:
        // package_access_tokens = 1, package_denied_tokens = 2,
        // app_access_tokens = 3, app_denied_tokens = 4.
        // access_token is uint64 (varint), not fixed64.
        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1:
                let subData = try decoder.readBytes()
                var sub = ProtobufDecoder(subData)
                var token = PackageToken()
                while let st = try sub.readTag() {
                    switch st.fieldNumber {
                    case 1: token.packageid = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case 2: token.accessToken = try sub.readVarint()
                    default: try sub.skip(wireType: st.wireType)
                    }
                }
                msg.packageAccessTokens.append(token)
            case 2: msg.packageAccessTokensDenied.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            case 3:
                let subData = try decoder.readBytes()
                var sub = ProtobufDecoder(subData)
                var token = AppToken()
                while let st = try sub.readTag() {
                    switch st.fieldNumber {
                    case 1: token.appid = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case 2: token.accessToken = try sub.readVarint()
                    default: try sub.skip(wireType: st.wireType)
                    }
                }
                msg.appAccessTokens.append(token)
            case 4: msg.appAccessTokensDenied.append(UInt32(truncatingIfNeeded: try decoder.readVarint()))
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}
