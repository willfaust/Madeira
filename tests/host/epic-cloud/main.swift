// Host driver for tests/host/check-epic-cloud.py: runs the production EpicCloudSaves.swift against a
// directory standing in for Epic's datastorage service.
//
//   driver selftest
//   driver pack  SRC CLOUD APP ACCOUNT FOLDER [YYYY.MM.dd-HH.mm.ss]   upload SRC as a new snapshot
//   driver fetch CLOUD DEST BACKUP APP ACCOUNT                         download the newest snapshot

import Foundation

struct DirTransport: EpicCloudTransport {
    var root: URL
    var prefix: String   // remote folder of the game, e.g. "ACC/savesync/APP"

    func list(app: String) async throws -> [EpicCloudObject] {
        let base = root.appendingPathComponent(prefix)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out = [EpicCloudObject]()
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(url.path.dropFirst(base.path.count + 1))
            out.append(EpicCloudObject(path: prefix + "/" + rel, readLink: url.path, writeLink: nil))
        }
        return out.sorted { $0.path < $1.path }
    }
    func read(_ object: EpicCloudObject) async throws -> Data { try Data(contentsOf: URL(fileURLWithPath: object.readLink!)) }
    func writeTargets(app: String, paths: [String]) async throws -> [EpicCloudObject] {
        paths.map { EpicCloudObject(path: $0, readLink: nil, writeLink: root.appendingPathComponent(prefix + "/" + $0).path) }
    }
    func write(_ object: EpicCloudObject, data: Data) async throws {
        let url = URL(fileURLWithPath: object.writeLink!)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   " : "FAIL ", what)
    if !ok { failures += 1 }
}

func selftest() {
    // the decision table
    typealias V = EpicSaveVerdict
    let a = ["s1": "aa"], b = ["s1": "bb"], c = ["s1": "cc"]
    let base = EpicSaveBaseline(device: a, cloud: a, snapshot: "x")
    check(EpicSavePlanner.decide(device: [:], cloud: nil, baseline: nil) == V.empty, "nothing anywhere: empty")
    check(EpicSavePlanner.decide(device: a, cloud: a, baseline: nil) == V.inSync, "same without a record: in sync")
    check(EpicSavePlanner.decide(device: [:], cloud: a, baseline: nil) == V.download, "empty device, cloud has saves: download")
    check(EpicSavePlanner.decide(device: a, cloud: nil, baseline: nil) == V.upload, "no cloud save yet: upload")
    check(EpicSavePlanner.decide(device: a, cloud: b, baseline: nil) == V.conflict, "differ, no record: conflict")
    check(EpicSavePlanner.decide(device: a, cloud: b, baseline: base) == V.download, "only the cloud changed: download")
    check(EpicSavePlanner.decide(device: b, cloud: a, baseline: base) == V.upload, "only the device changed: upload")
    check(EpicSavePlanner.decide(device: b, cloud: c, baseline: base) == V.conflict, "both changed: conflict")
    check(EpicSavePlanner.decide(device: a, cloud: nil, baseline: base) == V.inSync, "cloud emptied elsewhere: left alone")
    check(EpicSavePlanner.decide(device: b, cloud: nil, baseline: base) == V.upload, "cloud emptied, device changed: upload")
    let extra = EpicSaveBaseline(device: ["s1": "aa", "local": "zz"], cloud: a, snapshot: "x")
    check(EpicSavePlanner.decide(device: ["s1": "aa", "local": "zz"], cloud: a, baseline: extra) == V.inSync, "device extras recorded by a download stay in sync")

    // filters (utils/savegame_helper.py _filename_matches)
    check(EpicSaveConfig.matches("Saves/slot1.sav", ["*.sav"]), "glob matches")
    check(EpicSaveConfig.matches("Saves/slot1.sav", ["Saves/"]), "directory prefix matches")
    check(EpicSaveConfig.matches("a/b/config.ini", ["config.ini"]), "suffix matches")
    check(!EpicSaveConfig.matches("a/b/other.txt", ["*.sav", "Saves/"]), "no match")
    let inc = EpicSaveConfig(folder: "x", include: ["*.sav"], exclude: [])
    let exc = EpicSaveConfig(folder: "x", include: [], exclude: ["*.log"])
    check(inc.includes("a.sav") && !inc.includes("a.log"), "include list")
    check(exc.includes("a.sav") && !exc.includes("a.log"), "exclude list")
    let attrs: [String: Any] = ["CloudSaveFolder": ["value": "{AppData}/Game/Saved"], "CloudIncludeList": ["value": "*.sav, *.dat"]]
    let cfg = EpicSaveConfig.from(customAttributes: attrs)
    check(cfg?.folder == "{AppData}/Game/Saved" && cfg?.include == ["*.sav", "*.dat"], "customAttributes parsed")
    check(EpicSaveConfig.from(customAttributes: ["Other": ["value": "x"]]) == nil, "no CloudSaveFolder: no cloud saves")

    // save folder variables
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("epic-cloud-paths-\(getpid())")
    let drive = tmp.appendingPathComponent("drive_c"), user = drive.appendingPathComponent("users/steamuser")
    try? FileManager.default.createDirectory(at: user.appendingPathComponent("AppData/Local/MyGame"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let paths = EpicSavePaths(drive: drive, userFolder: user, installFolder: drive.appendingPathComponent("Program Files/Epic Games/G"), accountID: "ACC123")
    check(paths.resolve("{AppData}/mygame/Saved")?.path.hasSuffix("users/steamuser/AppData/Local/MyGame/Saved") == true, "{AppData} resolves, case-insensitively")
    check(paths.resolve("{UserDir}\\Games\\{EpicID}")?.path.hasSuffix("users/steamuser/Documents/Games/ACC123") == true, "{UserDir} and {EpicID}")
    check(paths.resolve("{UserSavedGames}/G")?.path.hasSuffix("users/steamuser/Saved Games/G") == true, "{UserSavedGames}")
    check(paths.resolve("{InstallDir}/Saves")?.path.hasSuffix("Epic Games/G/Saves") == true, "{InstallDir}")
    check(paths.resolve("{AppData}/../Roaming/G")?.path.hasSuffix("users/steamuser/AppData/Roaming/G") == true, "{AppData}/../Roaming stays inside the prefix")
    check(paths.resolve("{AppData}/../../../../../../../etc") == nil, "a path leaving drive_c is refused")
    check(paths.resolve("{Nonsense}/x") == nil && paths.resolve("C:/x") == nil, "unknown variables and absolute paths are refused")

    // chunk and hash basics
    check(EpicSaveWriter.rollingHash(Data()) == 0, "rolling hash of nothing is 0")
    let sample = Data("hello epic".utf8)
    if let built = try? EpicSaveWriter.chunk(sample, guid: [1, 2, 3, 4]) {
        check(built.file.count > 66 && built.path.hasPrefix("ChunksV4/"), "chunk file built (\(built.file.count) bytes, \(built.path))")
        let parsed = try? EpicChunk.parse(built.file)
        check(parsed?.count == EpicSaveWriter.chunkSize && parsed?.prefix(sample.count) == sample, "the reader inflates it back, padded to 1 MiB")
    } else { check(false, "chunk built") }
}

func run() async throws {
    let args = CommandLine.arguments
    guard args.count >= 2 else { print("usage"); exit(2) }
    switch args[1] {
    case "selftest":
        selftest()
        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    case "pack":
        let src = URL(fileURLWithPath: args[2]), cloud = URL(fileURLWithPath: args[3]), app = args[4], account = args[5], folder = args[6]
        let date = args.count > 7 ? EpicCloudSaves.date(ofBuildVersion: args[7]) ?? Date() : Date()
        let config = EpicSaveConfig(folder: folder, include: [], exclude: [])
        let saves = try EpicSaveScan.scan(src, config: config)
        let transport = DirTransport(root: cloud, prefix: "\(account)/savesync/\(app)")
        let result = try await EpicCloudSaves.upload(saves, app: app, accountID: account, config: config, transport: transport, date: date)
        print("packed \(result.files) files as \(result.version)")
    case "fetch":
        let cloud = URL(fileURLWithPath: args[2]), dest = URL(fileURLWithPath: args[3]), backup = URL(fileURLWithPath: args[4])
        let app = args[5], account = args[6]
        let transport = DirTransport(root: cloud, prefix: "\(account)/savesync/\(app)")
        guard let (snapshot, all) = try await EpicCloudSaves.latest(app: app, transport: transport) else { print("no snapshot"); exit(3) }
        let result = try await EpicCloudSaves.download(snapshot, all: all, into: dest, backup: backup, transport: transport)
        print("fetched \(result.files) files from \(snapshot.buildVersion), \(result.backedUp) backed up")
    default:
        print("unknown command"); exit(2)
    }
}

Task { do { try await run() } catch { print("ERROR: \(error)"); exit(1) }; exit(0) }
RunLoop.main.run()
