// SPDX-License-Identifier: GPL-3.0-or-later
// GOGSetup: the repository parser, the plan and the batch lines (docs/GOG.md, Redistributables).
import Foundation
let json: [String: Any] = ["depots": [
  ["dependencyId": "openAL", "readableName": "Open AL", "executable": ["path": "__redist/openAL/oalinst.exe", "arguments": "/s"], "manifest": String(repeating: "a", count: 32), "size": 100],
  ["dependencyId": "DirectX", "executable": ["path": "__redist/DirectX/DXSETUP.exe", "arguments": "/silent"], "manifest": String(repeating: "b", count: 32)],
  ["dependencyId": "MSVC2017_x64", "readableName": "VC 2017", "executable": ["path": "__redist\\MSVC2017_x64\\VC_redist.x64.exe", "arguments": "/install /quiet /norestart"], "manifest": String(repeating: "c", count: 32)],
  ["dependencyId": "PhysX", "executable": ["path": "__redist/PhysX/PhysX.msi", "arguments": "/qn"], "manifest": String(repeating: "d", count: 32)],
  ["dependencyId": "DOSBOX", "manifest": String(repeating: "e", count: 32)],
  ["dependencyId": "evil", "executable": ["path": "../../x.exe"], "manifest": String(repeating: "f", count: 32)],
  ["dependencyId": "bad", "manifest": "not-a-hash"],
]]
let repo = GOGDependency.parse(json)
precondition(repo.count == 6, "\(repo.count)")
precondition(repo.first { $0.id == "evil" }!.executable == "")
let plan = GOGSetup.plan(["openAL", "DirectX", "MSVC2017_x64", "PhysX", "DOSBOX", "dotNet4", "Missing", "openal"], repository: repo, hasMsiexec: false)
print("download:", plan.download.map(\.id)); print("run:", plan.run.map(\.id)); print("notes:", plan.notes.map { "\($0.id): \($0.note)" })
precondition(plan.run.map(\.id) == ["openAL"])
precondition(plan.download.map(\.id) == ["openAL", "DOSBOX"])
let drive = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drive_c-\(getpid())")
let lines = GOGSetup.batchLines(plan.run, folder: "C:\\GOG Games\\100% Game", drive: drive)
print(lines.joined(separator: "\n"))
precondition(GOGSetup.state("openAL", drive: drive) == .pending)
let r = GOGSetup.hostURL(GOGSetup.resultPath("MSVC2017_x64"), drive: drive)!
try FileManager.default.createDirectory(at: r.deletingLastPathComponent(), withIntermediateDirectories: true)
try "3010 \r\n".write(to: r, atomically: true, encoding: .utf8)
precondition(GOGSetup.state("MSVC2017_x64", drive: drive) == .done)
try "1603\r\n".write(to: r, atomically: true, encoding: .utf8)
precondition(GOGSetup.state("MSVC2017_x64", drive: drive) == .failed(1603))
precondition(GOGSetup.batchLines(plan.run, folder: "C:\\G", drive: drive).filter { $0.hasPrefix("echo [gog-setup]") }.count == 1)
GOGSetup.forget(["MSVC2017_x64"], drive: drive)
precondition(GOGSetup.state("MSVC2017_x64", drive: drive) == .pending)
let withMsi = GOGSetup.plan(["PhysX"], repository: repo, hasMsiexec: true)
precondition(withMsi.run.count == 1)
print(GOGSetup.batchLines(withMsi.run, folder: "C:\\G", drive: drive).joined(separator: "\n"))
print("ALL OK")
