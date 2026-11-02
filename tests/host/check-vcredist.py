#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Microsoft's Visual C++ runtime, taken out of Microsoft's installers on the device
(app/Madeira/VCRedist.swift, app/Madeira/CabinetReader.c, docs/LIBRARY.md).

Checks:
  * the pins: two packages (x64, x86) on download.visualstudio.microsoft.com over https,
    each URL carrying its own SHA-256, sizes and version set;
  * the wiring: setup's page with Set up later and revision 4, the Settings section behind
    the switch, the bridge's x86 overlay and its switch, the bridging header, the Xcode
    project entries for the three new files, the catalog entries, no Wine session anywhere;
  * compiled with the host C compiler and swiftc (CabinetReader.c, zlib, and the
    Foundation-only part of VCRedist.swift): version parsing and comparison, the entry-name
    rule, PE facts on synthetic bytes, the staging install, and, when the pinned installers
    are in the cache or can be downloaded (MADEIRA_VCREDIST_CACHE, default
    ~/.cache/madeira-tests), the real extraction: every expected DLL, the right machine, a
    signature directory, the pinned version, installedVersion() over the result.
Skips the compiled part without swiftc or a C compiler unless --require-swift.
"""
from pathlib import Path
import hashlib, os, re, shutil, subprocess, sys, tempfile, urllib.request

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "app/Madeira"
failures = 0

def require(cond, what):
    global failures
    print(("ok   " if cond else "FAIL ") + what)
    if not cond: failures += 1

def block(src, start, end="\n}\n"):
    i = src.index(start)
    return src[i:src.index(end, i) + len(end)]

redist = (APP / "VCRedist.swift").read_text(encoding="utf-8")
onboarding = (APP / "Onboarding.swift").read_text(encoding="utf-8")
library = (APP / "Library.swift").read_text(encoding="utf-8")
bridge = (APP / "WineProcessBridge.m").read_text(encoding="utf-8")
header = (APP / "Madeira-Bridging-Header.h").read_text(encoding="utf-8")
project = (ROOT / "app/Madeira.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
catalog = (APP / "ConfigCatalog.generated.swift").read_text(encoding="utf-8")

# ------------------------------------------------------------------ static: the pins
pins = block(redist, "enum VCRedistPin {")
packages = re.findall(r'arch: "(x64|x86)", title: "([^"]+)",\s*url: URL\(string: "([^"]+)"\)!,\s*sha256: "([0-9a-f]{64})", bytes: ([0-9_]+), entrySuffix: "([^"]+)"\)', pins)
require(len(packages) == 2 and {p[0] for p in packages} == {"x64", "x86"}, "two packages, x64 and x86")
pinned = {}
for arch, title, url, sha, size, suffix in packages:
    pinned[arch] = (url, sha, int(size.replace("_", "")), suffix)
    require(url.startswith("https://download.visualstudio.microsoft.com/download/pr/") and url.endswith(f"/VC_redist.{arch}.exe"),
            f"{arch}: a versioned https URL on download.visualstudio.microsoft.com")
    require(sha.upper() in url, f"{arch}: the URL carries the pinned SHA-256")
    require(int(size.replace("_", "")) > 10_000_000, f"{arch}: a plausible size")
    require(suffix == (".dll_amd64" if arch == "x64" else ".dll_x86"), f"{arch}: the cabinet entry suffix")
version = re.search(r'static let version = "(14\.\d+\.\d+\.\d+)"', pins)
require(version is not None and 'static let host = "download.visualstudio.microsoft.com"' in pins, "the host and the version are pinned")
require(redist.count('"vcruntime140_1.dll"') >= 2 and 'arch == "x86" ? dllNames.filter { $0 != "vcruntime140_1.dll" }' in redist,
        "x86 expects no vcruntime140_1.dll (Microsoft ships none)")

# ------------------------------------------------------------------ static: wiring
require('case welcome, localDevVPN = "localdevvpn", jit, signIn = "sign-in", dockClient = "dock-client",\n'
        '             wineMono = "wine-mono", vcRedist = "vc-redist", done' in onboarding
        and "case .vcRedist: return 4" in onboarding and "static let revision = 4" in onboarding,
        "setup: the vc-redist step, introduced by revision 4")
page = block(onboarding, "private var vcRedistPage: some View {")
require('secondary("Set up later") { model.next() }' in page and "redist.install()" in page and "No Windows session" in page,
        "setup page: Set up later, install through the model, says no session runs")
require("case .vcRedist: vcRedistPage" in onboarding and "offerVCRedist = Self.vcRedistOffered()" in onboarding,
        "setup shows the page while the device lacks the runtime")
require("VCRedistSettingsSection()" in library and "VCRedistModel.enabled" in library, "Settings: the section, behind the switch")
require('MadeiraConfig.flag("MADEIRA_VCREDIST")' in redist, "the feature switch is read through MadeiraConfig.flag")
for forbidden in ["runWineFullSequence", "launchRequest", "wine_process_start", "MADEIRA_EXE", "install.cmd", "startSetupSession"]:
    require(forbidden not in redist, f"VCRedist.swift: no {forbidden} (no Wine session)")
require("wine_process_is_running() == 0" in block(redist, "    func install() {") and "wine_process_is_running() == 0" in block(redist, "    func remove() {"),
        "install and remove refuse while a session runs")
require('#include "CabinetReader.h"' in header, "the bridging header exposes the cabinet reader")
require('getenv("MADEIRA_VCREDIST_X86")' in bridge and "madeira_overlay_vcruntime32(fm, prefix);" in bridge, "the bridge overlays Documents/vcruntime32 into syswow64, behind its switch")
overlay = block(bridge, "static void madeira_overlay_vcruntime32(NSFileManager *fm, NSString *prefix)")
require('@"vcruntime32"' in overlay and "drive_c/windows/syswow64" in overlay and "createSymbolicLinkAtPath" in overlay, "the x86 overlay links into syswow64")
require(bridge.index("madeira_link_syswow64(fm, prefix, bundlePath);") < bridge.index("madeira_overlay_vcruntime32(fm, prefix);"),
        "the x86 overlay runs after the syswow64 farm links, so removing the folder restores the builtins")
require('stringByAppendingPathComponent:@"vcruntime"];' in bridge, "the x64 folder is the bridge's existing Documents/vcruntime source")
for ident, count in (("A1000712 /* VCRedist.swift in Sources */", 2), ("A2000712 /* VCRedist.swift */", 3),
                     ("A1000713 /* CabinetReader.c in Sources */", 2), ("A2000713 /* CabinetReader.c */", 3), ("A2000714 /* CabinetReader.h */", 2)):
    require(project.count(ident) == count, f"Xcode project: {ident.split('/*')[1].split('*/')[0].strip()} ({count} mentions)")
require('key: "env.MADEIRA_VCREDIST"' in catalog and 'key: "env.MADEIRA_VCREDIST_X86"' in catalog, "catalog: both switches")
require(not re.search(r'LogStore.shared.log\([^\n]*\\\((account|token|signIn|url|path)', redist), "no account, token or path in a log line")

# ------------------------------------------------------------------ compiled
SWIFTC = os.environ.get("SWIFTC") or shutil.which("swiftc") or str(Path.home() / ".local/share/swiftly/bin/swiftc")
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
if not Path(SWIFTC).exists() or not CC:
    if "--require-swift" in sys.argv:
        require(False, "swiftc and a C compiler available")
    else:
        print("SKIP compiled checks: no swiftc or C compiler")
else:
    cache = Path(os.environ.get("MADEIRA_VCREDIST_CACHE") or Path.home() / ".cache/madeira-tests")
    cache.mkdir(parents=True, exist_ok=True)
    installers = {}
    for arch, (url, sha, size, _) in pinned.items():
        target = cache / f"VC_redist.{arch}.exe"
        if not target.exists() or target.stat().st_size != size:
            try:
                print(f"downloading {url}")
                with urllib.request.urlopen(url, timeout=120) as r, open(target, "wb") as f:
                    shutil.copyfileobj(r, f)
            except Exception as e:  # noqa: BLE001
                print(f"SKIP real installer {arch}: {e}")
                continue
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        if target.stat().st_size == size and digest == sha:
            installers[arch] = target
        else:
            require(False, f"{arch}: the cached installer matches the pin ({target.stat().st_size} bytes, sha256 {digest[:16]}...)")

    slice_ = redist[redist.index("// MARK: - Pin"):redist.index("// MARK: - Model")]
    checks = r'''
import Foundation
var failures = 0
func expect(_ c: Bool, _ what: String) { print((c ? "ok   " : "FAIL ") + what); if !c { failures += 1 } }
@main struct Checks {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let packages = VCRedistPin.packages
        expect(packages.map(\.arch) == ["x64", "x86"] && VCRedistPin.totalBytes == packages.map(\.bytes).reduce(0, +)
               && VCRedistPin.totalMegabytes > 30, "packages and sizes")
        expect(VCRedistPin.dllNames.count == 14 && VCRedistPin.expectedNames("x64").count == 14 && VCRedistPin.expectedNames("x86").count == 13,
               "14 names for x64, 13 for x86")
        expect(VCRedistInstaller.versionParts("v14.44.35211.00") == [14, 44, 35211, 0] && VCRedistInstaller.versionParts("installed") == nil, "version parsing")
        expect(VCRedistInstaller.atLeastPinned("14.44.35211.0") && VCRedistInstaller.atLeastPinned("14.50.1.0")
               && !VCRedistInstaller.atLeastPinned("14.42.34433.0") && !VCRedistInstaller.atLeastPinned("x"), "at least the pinned version")
        expect(VCRedistInstaller.dllName(entry: "MSVCP140.dll_amd64", package: packages[0]) == "msvcp140.dll"
               && VCRedistInstaller.dllName(entry: "msvcp140.dll_amd64", package: packages[1]) == nil
               && VCRedistInstaller.dllName(entry: "mfc140chs.dll_amd64", package: packages[0]) == nil
               && VCRedistInstaller.dllName(entry: "vcruntime140_1.dll_x86", package: packages[1]) == nil
               && VCRedistInstaller.dllName(entry: "vcomp140.dll_x86", package: packages[1]) == "vcomp140.dll", "entry names: suffix, architecture, wanted set")

        // Synthetic PE: MZ header, PE signature, x64 machine, PE32+ optional header with a security directory, VS_FIXEDFILEINFO.
        var pe = Data(count: 0x400)
        pe[0] = 0x4D; pe[1] = 0x5A; pe[0x3c] = 0x80
        pe[0x80] = 0x50; pe[0x81] = 0x45; pe[0x84] = 0x64; pe[0x85] = 0x86
        pe[0x98] = 0x0b; pe[0x99] = 0x02
        let security = 0x80 + 24 + 112 + 4 * 8
        pe[security + 4] = 0x10
        pe[0x200] = 0xBD; pe[0x201] = 0x04; pe[0x202] = 0xEF; pe[0x203] = 0xFE
        pe[0x208] = 0x2C; pe[0x209] = 0x00; pe[0x20A] = 0x0E; pe[0x20B] = 0x00   // 14.44
        pe[0x20C] = 0x00; pe[0x20D] = 0x00; pe[0x20E] = 0x8B; pe[0x20F] = 0x89   // 35211.0
        let facts = VCRedistInstaller.peFacts(pe)
        expect(facts == VCRedistInstaller.PEFacts(machine: 0x8664, signed: true, version: "14.44.35211.0"), "PE facts: machine, signature directory, version")
        expect(VCRedistInstaller.peFacts(Data("not a program".utf8)) == nil, "not a PE")
        expect((try? VCRedistInstaller.check(pe, name: "x.dll", package: packages[0])) != nil
               && (try? VCRedistInstaller.check(pe, name: "x.dll", package: packages[1])) == nil, "check: the architecture must match")

        // Staging install into a temporary folder, then the version read back.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vcredist-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let folder = tmp.appendingPathComponent("vcruntime", isDirectory: true)
        var files: [String: Data] = [:]
        for name in VCRedistPin.expectedNames("x64") { files[name] = pe }
        try VCRedistInstaller.install(files, into: folder)
        try VCRedistInstaller.install(files, into: folder)   // replaces an existing folder in one step
        expect(VCRedistInstaller.installedVersion(in: folder, package: packages[0]) == "14.44.35211.0"
               && VCRedistInstaller.installedVersion(in: folder, package: packages[1]) == nil
               && !FileManager.default.fileExists(atPath: folder.path + ".new"), "staged install, read back by architecture")

        // The real installers, when the host has them.
        for package in packages {
            guard let path = env["MADEIRA_VCREDIST_" + package.arch.uppercased()] else { print("SKIP real extraction " + package.arch); continue }
            var seen = 0.0
            let found = try VCRedistInstaller.extract(installer: URL(fileURLWithPath: path), package: package) { seen = $0 }
            let names = Set(VCRedistPin.expectedNames(package.arch))
            expect(Set(found.keys) == names && seen == 1, "\(package.arch): every expected DLL came out of the installer")
            let machine: UInt16 = package.arch == "x86" ? 0x14c : 0x8664
            expect(found.values.allSatisfy { data in
                let f = VCRedistInstaller.peFacts(data); return f?.machine == machine && f?.signed == true && f?.version == VCRedistPin.version
            }, "\(package.arch): machine, signature directory and the pinned version on every DLL")
            let out = tmp.appendingPathComponent("real-" + package.arch, isDirectory: true)
            try VCRedistInstaller.install(found, into: out)
            expect(VCRedistInstaller.installedVersion(in: out, package: package) == VCRedistPin.version, "\(package.arch): the installed folder reads back the pinned version")
        }
        try? FileManager.default.removeItem(at: tmp)
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Visual C++ runtime Swift checks")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="madeira-vcredist-") as tmp:
        tmp = Path(tmp)
        (tmp / "redist.swift").write_text("import Foundation\n" + slice_)
        (tmp / "checks.swift").write_text(checks)
        cc = subprocess.run([CC, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str(APP), "-c", str(APP / "CabinetReader.c"), "-o", str(tmp / "cab.o")],
                            capture_output=True, text=True)
        if cc.returncode != 0:
            print(cc.stderr[-3000:])
            require(False, "CabinetReader.c compiles with -Wall -Wextra -Werror")
        else:
            build = subprocess.run([SWIFTC, "-parse-as-library", "-swift-version", "5", "-import-objc-header", str(APP / "CabinetReader.h"),
                                    "-o", str(tmp / "check"), str(tmp / "redist.swift"), str(tmp / "checks.swift"), str(tmp / "cab.o"), "-lz"],
                                   capture_output=True, text=True)
            if build.returncode != 0:
                print(build.stderr[-4000:])
                require(False, "the pin, PE, cabinet and install code compiles with the cabinet reader")
            else:
                env = {**os.environ, **{f"MADEIRA_VCREDIST_{a.upper()}": str(p) for a, p in installers.items()}}
                run = subprocess.run([str(tmp / "check")], capture_output=True, text=True, env=env)
                print(run.stdout.rstrip())
                if run.stderr.strip(): print(run.stderr[-2000:])
                require(run.returncode == 0, "compiled checks pass")

if failures:
    print(f"FAIL: check-vcredist ({failures} failure(s))")
    sys.exit(1)
print("PASS: check-vcredist; device execution still required")
