#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Curator fix pack tool.
//   curator-fixpack.swift keygen            makes ~/.config/triptych/curator-fixpack.key (never inside the repo) and prints the public key
//   curator-fixpack.swift pubkey            prints the public key (base64) for CuratorFixPack.publicKeyBase64
//   curator-fixpack.swift sign <in> <out>   <in> is the pack JSON, <out> becomes the signed envelope bundled as curator-fixpack.json
import CryptoKit
import Foundation

let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/triptych/curator-fixpack.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("no key at \(keyURL.path); run keygen") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    guard !FileManager.default.fileExists(atPath: keyURL.path) else { fail("\(keyURL.path) exists; refusing to overwrite") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "pubkey":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 3 else { fail("usage: sign <in> <out>") }
    let payload = try Data(contentsOf: URL(fileURLWithPath: args[args.startIndex + 1]))
    _ = try JSONSerialization.jsonObject(with: payload)
    let signature = try loadKey().signature(for: payload)
    let envelope: [String: String] = ["payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()]
    try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: args[args.startIndex + 2]), options: .atomic)
default:
    fail("usage: curator-fixpack.swift keygen | pubkey | sign <in> <out>")
}
