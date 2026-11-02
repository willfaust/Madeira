// Host driver for tests/host/check-ea-formats.py: runs the production EAFormats.swift
// against values the Python side computes with its own libraries.
//
//   driver selftest                       the pure checks (AES, LSX key, zip, XML, licence, hash)
//   driver aes-ecb HEXKEY HEXPLAIN        AES-128-ECB (PKCS#7) of the bytes, hex
//   driver aes-cbc HEXKEY HEXPLAIN        AES-128-CBC, zero IV (PKCS#7), hex
//   driver lsx-key SEED                   the session key for a 16-bit seed, hex
//   driver hash VERSION JSON              the machine hash of a profile (JSON) for a hash version
//   driver pcsign-verify VALUE            1 when a pc_sign value's signature matches its payload
//   driver launch-code YYYY-MM-DD         the day's launch code
//   driver zip FILE                       the entries of a zip file, one "name crc method csize usize offset" per line

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   " : "FAIL ", what)
    if !ok { failures += 1 }
}

func hex(_ data: Data) -> String { EAHex.encode(data) }

func selftest() {
    // AES-128 against FIPS-197's appendix C.1 vector (one block, no padding involved in the block).
    let aes = EAAES128(key: Array(EAHex.decode("000102030405060708090a0b0c0d0e0f")!))
    let block = Array(EAHex.decode("00112233445566778899aabbccddeeff")!)
    let cipher = aes.encryptBlock(block)
    check(hex(Data(cipher)) == "69c4e0d86a7b0430d8cdb78070b4c55a", "AES-128 block encrypt (FIPS-197 C.1)")
    check(aes.decryptBlock(cipher) == block, "AES-128 block decrypt")
    let text = Data("<LSX><Request recipient=\"EALS\" id=\"1\"><GetProfile index=\"0\" version=\"1.0\"/></Request></LSX>".utf8)
    check(aes.ecbDecrypt(aes.ecbEncrypt(text)) == text, "ECB round trip with padding")
    check(aes.cbcDecrypt(aes.cbcEncrypt(text)) == text, "CBC round trip with padding")
    check(aes.ecbDecrypt(Data(count: 15)) == nil, "ECB rejects a length that is not a block multiple")

    // The challenge exchange.
    let challenge = "cacf897a20b6d612ad0c05e011df52bb"
    let response = EALSXCrypto.challengeResponse(challenge)
    check(EALSXCrypto.checkChallengeResponse(response, challenge: challenge), "challenge response verifies")
    check(!EALSXCrypto.checkChallengeResponse(response, challenge: "other"), "challenge response is bound to the challenge")
    check(EALSXCrypto.sessionKey(version: "2", acceptedKey: response) == EALSXCrypto.fixedKey, "version 2 keeps the fixed key")
    check(EALSXCrypto.sessionKey(version: "9", acceptedKey: response) == nil, "unknown encryption version refused")
    check(EALSXCrypto.derivedKey(seed: 0) == EALSXCrypto.fixedKey, "seed 0 keeps the fixed key")
    let key3 = EALSXCrypto.sessionKey(version: "3", acceptedKey: response)!
    let bytes = Array(response.utf8)
    check(key3 == EALSXCrypto.derivedKey(seed: UInt16(bytes[0]) << 8 | UInt16(bytes[1])), "version 3 seeds from the accepted key")
    let secret = "<LSX><Response sender=\"EALS\" id=\"1\"><ErrorSuccess Code=\"0\" Description=\"\"/></Response></LSX>"
    check(EALSXCrypto.decrypt(EALSXCrypto.encrypt(secret, key: key3), key: key3) == secret, "session encryption round trip")
    check(EALSXCrypto.decrypt(EALSXCrypto.encrypt(secret, key: key3).uppercased(), key: key3) == secret, "hex of either case decrypts")

    // LSX documents.
    let packet = "<LSX><Request recipient=\"EALS\" id=\"3\"><GetSetting SettingId=\"IsIgoEnabled\" version=\"1.0\"/></Request></LSX>\0" +
        "<LSX><Event sender=\"game\"><SomethingHappened/></Event></LSX>\0<LSX><Request recipient=\"EALS\" id=\"4\"><ChallengeResponse response=\"ab\" key=\"cd\" version=\"3\"><ContentId>1000000</ContentId><Title>Game</Title></ChallengeResponse></Request></LSX>"
    let documents = EALSX.documents(in: packet)
    check(documents.count == 3, "three documents in one packet")
    let first = EALSX.request(documents[0])
    check(first?.name == "GetSetting" && first?.id == "3" && first?.attribute("SettingId") == "IsIgoEnabled", "request name, id and attribute")
    check(EALSX.request(documents[1]) == nil && EALSX.isEvent(documents[1]), "an event is not a request")
    let third = EALSX.request(documents[2])
    check(third?.value("ContentId") == "1000000" && third?.value("Title") == "Game" && third?.attribute("version") == "3", "request children")
    check(EALSX.request("<LSX><Request recipient=\"EALS\" id=\"5\"><GetConfig version=\"\" /></Request></LSX>")?.name == "GetConfig", "empty attribute value parses")
    let reply = EALSX.response(to: first!, EAXML.element("GetSettingResponse", [("Setting", "a \"quoted\" & <value>")]))
    check(reply == "<LSX><Response sender=\"EALS\" id=\"3\"><GetSettingResponse Setting=\"a &quot;quoted&quot; &amp; &lt;value&gt;\"/></Response></LSX>", "response document with escaping")
    check(EALSX.event(EAXML.element("Challenge", [("build", "release"), ("key", "k"), ("version", "10,5,30,15625")]))
          == "<LSX><Event sender=\"EALS\"><Challenge build=\"release\" key=\"k\" version=\"10,5,30,15625\"/></Event></LSX>", "challenge event")
    check(EAXML.element("GetConfigResponse", children: EAXML.element("Service", [("Name", "EALS"), ("Facility", "LOGIN")]))
          == "<GetConfigResponse><Service Name=\"EALS\" Facility=\"LOGIN\"/></GetConfigResponse>", "element with children")

    // installerdata.xml, the current and the older form, and a UTF-16 copy.
    let dip = """
    <?xml version="1.0" encoding="UTF-8"?>
    <DiPManifest version="4.0">
      <buildMetaData><featureFlags autoUpdateEnabled="1"/><gameVersion version="2.0.0.48602"/><requirements osMinVersion="6.1" osReqs64Bit="1"/></buildMetaData>
      <contentIDs><contentID>1000800</contentID><contentID>1000801</contentID></contentIDs>
      <gameTitles><gameTitle locale="de_DE">Spiel</gameTitle><gameTitle locale="en_US">The Game</gameTitle></gameTitles>
      <runtime>
        <launcher uid="trial"><filePath>[HKEY_LOCAL_MACHINE\\SOFTWARE\\Studio\\Game\\Install Dir]Game\\Bin\\Trial.exe</filePath><parameters></parameters><trial>1</trial></launcher>
        <launcher uid="full"><filePath>[HKEY_LOCAL_MACHINE\\SOFTWARE\\Studio\\Game\\Install Dir]Game\\Bin\\Game.exe</filePath><parameters>-windowed</parameters><executeElevated>0</executeElevated><requires64BitOS>1</requires64BitOS><trial>0</trial></launcher>
      </runtime>
      <touchup><filePath>__Installer/Touchup.exe</filePath><parameters>-locale {locale}</parameters></touchup>
    </DiPManifest>
    """
    let parsed = EAInstallerData.parse(Data(dip.utf8))
    check(parsed?.launcher?.filePath.hasSuffix("Game\\Bin\\Game.exe") == true && parsed?.launcher?.parameters == "-windowed", "DiP manifest: the full game's launcher")
    check(parsed?.gameVersion == "2.0.0.48602" && parsed?.contentIDs == ["1000800", "1000801"] && parsed?.title == "The Game", "DiP manifest: version, content ids, title")
    check(parsed?.touchupPath == "__Installer/Touchup.exe", "DiP manifest: touchup")
    let utf16 = dip.data(using: .utf16)!
    check(EAInstallerData.parse(utf16)?.launcher?.parameters == "-windowed", "UTF-16 manifest")
    let old = "<?xml version=\"1.0\"?><game gameVersion=\"1.2\" manifestVersion=\"1\"><executable><filePath>Bin\\Old.exe</filePath><parameters>-old</parameters></executable></game>"
    let legacy = EAInstallerData.parse(Data(old.utf8))
    check(legacy?.launcher?.filePath == "Bin\\Old.exe" && legacy?.gameVersion == "1.2", "older manifest form")
    check(EAInstallerData.parse(Data("<nothing/>".utf8)) == nil, "a manifest without launchers is nil")

    // Registry-prefixed paths.
    let path = EARegistryPath("[HKEY_LOCAL_MACHINE\\SOFTWARE\\Studio\\Game\\Install Dir]\\Game\\Bin\\Game.exe")
    check(path.key == "SOFTWARE\\Studio\\Game" && path.valueName == "Install Dir" && path.relative == "Game\\Bin\\Game.exe", "registry path split")
    let plain = EARegistryPath("Game/Bin/Game.exe")
    check(plain.key == nil && plain.relative == "Game\\Bin\\Game.exe", "plain path")

    // Licence files.
    let licence = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><License xmlns=\"http://ea.com/license\"><CipherKey>abc</CipherKey><MachineHash>deadbeef</MachineHash><ContentId>1000800</ContentId><UserId>12345</UserId><GameToken>tok</GameToken><GrantTime>2026-10-29T10:00:00Z</GrantTime><StartTime>2026-10-29T10:00:00Z</StartTime><Nonce>1</Nonce></License>"
    let signature = Data(repeating: 7, count: 64).base64EncodedString()
    let packed = EALicenseFile.pack(xml: licence, signature: signature, decodeSignature: true)!
    check(packed.count == 65 + ((licence.utf8.count / 16) + 1) * 16, "licence file layout")
    check(packed[0..<64] == Data(repeating: 7, count: 64) && packed[64] == 0, "decoded signature padded to 65 bytes")
    check(EALicenseFile.unpack(packed) == licence, "licence file round trip")
    let encoded = EALicenseFile.pack(xml: licence, signature: "c2ln", decodeSignature: false)!
    check(encoded[0..<4] == Data("c2ln".utf8) && encoded[4] == 0, "text signature kept as text")
    check(EALicenseFile.pack(xml: licence, signature: String(repeating: "A", count: 100), decodeSignature: false) == nil, "a signature too long for the slot is refused")
    let info = EALicenseInfo(xml: licence)
    check(info?.contentID == "1000800" && info?.userID == "12345" && info?.machineHash == "deadbeef" && info?.gameToken == "tok", "licence fields")
    check(info?.startTime == EALicenseInfo.date("2026-10-29T10:00:00Z"), "licence start time")

    // The machine hash's shape (values are checked against Python by the runner).
    var profile = EAHardwareProfile()
    profile.gpuPNPDeviceID = "PCI\\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00\\00000000"
    let (hash4, input4) = profile.machineHash(version: 4)
    check(hash4.count == 40 && input4.hasPrefix("Apple Inc.;None;Apple Inc.;Serial number;00000000;PCI\\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00;GenuineIntel;2F8BFBF3000A0661;"),
          "version 4 hash input and length")
    let (_, input1) = profile.machineHash(version: 1)
    check(input1 == "Apple Inc.;None;iPad;Apple Inc.;Serial number;20260101000000.000000+000;12345-oem-0000001-54321;", "version 1 hash input")
    let (_, input2) = profile.machineHash(version: 2)
    check(input2.hasSuffix(";genuineintel;".uppercased().lowercased().replacingOccurrences(of: "genuineintel", with: "GenuineIntel") + "2f8bfbf3;82d8230f;Unknown ARM CPU;"), "version 2 hash input ends with the flags and brand")
    check(profile.gpuDeviceID == 1, "pc_sign gid from the PNP id")
    check(EAHardwareProfile.cpuECX(avx: true) == 0xBED8_330F && EAHardwareProfile.cpuECX(avx: false) == 0x82D8_230F, "CPUID ECX with and without AVX")
    check(EAHardwareProfile.wmiDate(Date(timeIntervalSince1970: 1_767_225_600.5)) == "20260101000000.500000+000", "WMI date form")
    let sign = EAPCSign.value(profile: profile, keyVersion: "v2", date: Date(timeIntervalSince1970: 1_767_225_600))
    check(sign.split(separator: ".").count == 2, "pc_sign is payload.signature")
    let payload = String(sign.split(separator: ".")[0])
    var padded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded += "=" }
    let json = String(data: Data(base64Encoded: padded)!, encoding: .utf8)!
    check(json == "{\"av\":\"v1\",\"bsn\":\"Serial number\",\"gid\":1,\"hsn\":\"None\",\"mid\":\"\(profile.machineID)\",\"msn\":\"None\",\"sv\":\"v2\",\"ts\":\"2026-01-01 00:00:00:000\"}",
          "pc_sign payload fields and order")

    // The daily launch code, against the published arithmetic.
    let date = EALicenseInfo.date("2026-10-29T12:00:00Z")!
    let time: UInt32 = (104_729 &* 2026) ^ (10 &* 224_737) ^ (29 &* 350_377)
    check(EALSXCrypto.launchCode(date: date) == time ^ (time << 16) ^ (time >> 16), "launch code for 2026-10-29")

    // Hex and CRC.
    check(EAHex.decode("0A ff") == Data([0x0A, 0xFF]) && EAHex.decode("abc") == nil, "hex decoding")
    var crc = EACRC32(); crc.update(Data("123456789".utf8))
    check(crc.checksum == 0xCBF4_3926, "CRC-32 check value")
    check(EAFNV.hash64(Data("a".utf8)) == 0xaf63dc4c8601ec8c, "FNV-1a 64 of 'a'")

    // Zip paths.
    check(EAZipDirectory.safeComponents("Game/Bin/../x.exe") == nil && EAZipDirectory.safeComponents("C:/x") == nil, "unsafe zip paths refused")
    check(EAZipDirectory.safeComponents("Game\\Bin\\x.exe") == ["Game", "Bin", "x.exe"], "zip path parts")

    // PE version: a minimal VS_FIXEDFILEINFO inside junk.
    var pe = Data(repeating: 0x55, count: 100)
    pe.append(contentsOf: [0xBD, 0x04, 0xEF, 0xFE, 0x00, 0x00, 0x01, 0x00])
    pe.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])            // file version
    pe.append(contentsOf: [0x07, 0x00, 0x04, 0x00, 0x00, 0x00, 0x06, 0x00])   // product version 4.7 / 6.0
    pe.append(Data(repeating: 0, count: 40))
    let version = EAPEVersion.productVersion(pe)
    check(version == EAPEVersion.Version(major: 4, minor: 7, patch: 6, build: 0), "product version from VS_FIXEDFILEINFO")
    check(EAPEVersion.hashVersion(version) == 3 && EAPEVersion.hashVersion(EAPEVersion.Version(major: 5, minor: 0, patch: 0, build: 0)) == 4
          && EAPEVersion.hashVersion(EAPEVersion.Version(major: 4, minor: 7, patch: 0, build: 0)) == 2
          && EAPEVersion.hashVersion(EAPEVersion.Version(major: 4, minor: 1, patch: 0, build: 0)) == 1
          && EAPEVersion.hashVersion(EAPEVersion.Version(major: 3, minor: 9, patch: 0, build: 0)) == 0 && EAPEVersion.hashVersion(nil) == 1,
          "hash version from the activation library's version")
}

let args = CommandLine.arguments.dropFirst()
switch args.first ?? "selftest" {
case "selftest":
    selftest()
    print(failures == 0 ? "\nAll EA format checks passed." : "\n\(failures) EA format check(s) failed.")
    exit(failures == 0 ? 0 : 1)
case "aes-ecb":
    let aes = EAAES128(key: Array(EAHex.decode(args.dropFirst().first!)!))
    print(hex(aes.ecbEncrypt(EAHex.decode(args.dropFirst(2).first!)!)))
case "aes-cbc":
    let aes = EAAES128(key: Array(EAHex.decode(args.dropFirst().first!)!))
    print(hex(aes.cbcEncrypt(EAHex.decode(args.dropFirst(2).first!)!)))
case "lsx-key":
    print(hex(Data(EALSXCrypto.derivedKey(seed: UInt16(args.dropFirst().first!)!))))
case "hash":
    let version = Int(args.dropFirst().first!)!
    let profile = try! JSONDecoder().decode(EAHardwareProfile.self, from: Data(args.dropFirst(2).first!.utf8))
    let (hash, input) = profile.machineHash(version: version)
    print(hash); print(input)
case "pcsign-verify":
    let parts = args.dropFirst().first!.split(separator: ".").map(String.init)
    let payload = parts[0]
    var padded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded += "=" }
    let json = (try? JSONSerialization.jsonObject(with: Data(base64Encoded: padded)!)) as? [String: Any]
    let keyVersion = (json?["sv"] as? String) ?? "v1"
    let expected = EAPCSign.base64url(EADigest.hmacSHA256(key: EAPCSign.keys[keyVersion]!, data: Data(payload.utf8)))
    print(parts.count == 2 && parts[1] == expected ? "1" : "0")
case "launch-code":
    let date = EALicenseInfo.date(args.dropFirst().first! + "T12:00:00Z")!
    print(EALSXCrypto.launchCode(date: date))
case "zip":
    let data = try! Data(contentsOf: URL(fileURLWithPath: args.dropFirst().first!))
    let tail = data.suffix(min(data.count, 256 * 1024))
    let location: EAZipDirectory.Location
    switch try! EAZipDirectory.locate(tail: Data(tail), fileSize: Int64(data.count)) {
    case .found(let found): location = found
    case .needsRecord(let offset): location = try! EAZipDirectory.location(zip64Record: data.subdata(in: Int(offset)..<Int(offset) + 56))
    }
    let entries = try! EAZipDirectory.entries(data.subdata(in: Int(location.offset)..<Int(location.offset + location.size)))
    for entry in entries {
        let headerLength = EAZipDirectory.localHeaderLength(data.subdata(in: Int(entry.localHeaderOffset)..<Int(entry.localHeaderOffset) + 30)) ?? -1
        print("\(entry.name)\t\(entry.crc32)\t\(entry.method)\t\(entry.compressedSize)\t\(entry.uncompressedSize)\t\(entry.localHeaderOffset)\t\(headerLength)")
    }
case "inflate":
    // inflate <raw deflate file> <piece size> <output file>: feeds the stream in pieces,
    // writes what came out, prints "finished=<0|1>" or "error=<reason>".
    let input = try! Data(contentsOf: URL(fileURLWithPath: args.dropFirst().first!))
    let piece = max(1, Int(args.dropFirst(2).first!)!)
    var inflate = EAInflate()
    var output = Data()
    var offset = 0
    do {
        repeat {
            let end = min(input.count, offset + piece)
            output.append(contentsOf: try inflate.feed(input[offset..<end]))
            offset = end
        } while offset < input.count
        try! output.write(to: URL(fileURLWithPath: args.dropFirst(3).first!))
        print("finished=\(inflate.finished ? 1 : 0)")
    } catch {
        try! output.write(to: URL(fileURLWithPath: args.dropFirst(3).first!))
        print("error=\(error)")
    }
default:
    print("unknown command"); exit(2)
}
