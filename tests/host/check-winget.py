#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The winget source without Wine (app/Madeira/WingetCore.swift).

The Swift fixture compiles the real WingetCore.swift and checks, on a small index built here with
the real schema: search order (exact beats prefix beats substring, tag-only matches last, LIKE
characters escaped), the versionData decoder (28-byte header, "CK", raw DEFLATE), the YAML subset
and the typed manifest on a real merged manifest (a list at its key's indent, folded scalars,
installer-level overrides of top-level defaults), and the hash chain helper. macOS hosts only
(CryptoKit, Compression): other hosts run the source checks; --require-swift fails instead.
"""
from pathlib import Path
import argparse, hashlib, os, shutil, sqlite3, subprocess, tempfile, zlib

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
core = (root / 'app/Madeira/WingetCore.swift').read_text()
plan = (root / 'app/Madeira/WingetPlan.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
failures = 0


def check(ok, label):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + label)
    failures += 0 if ok else 1


for name in ('WingetCore.swift', 'WingetPlan.swift', 'WingetCatalog.swift', 'WingetViews.swift'):
    check(project.count(name) >= 4, name + ' is in the project')
check('rowid IN (SELECT package FROM tags2_map WHERE tag IN (SELECT rowid FROM tags2' in core,
      'tags and commands use uncorrelated subqueries')
check('SQLITE_OPEN_READONLY' in core, 'the index opens read-only')

MANIFEST = """Commands:
- code
Icons:
- IconFileType: ico
  IconUrl: https://example.test/a.ico
- IconFileType: png
  IconUrl: https://example.test/a.png
InstallerLocale: en-US
InstallerSwitches:
  Custom: /mergetasks=!runcode
InstallerType: inno
Installers:
- Architecture: x64
  InstallerSha256: 706BA8B326D87637A923676076EB2936060BE6DE5C0AE4691B3F76D2CAC54F08
  InstallerUrl: https://example.test/user.exe
  Scope: user
- Architecture: x86
  InstallerSha256: C5F66401B1F55092FCBDE213BF79126B1085D9AF5BFEAE6B0A04BEB81B6A4270
  InstallerType: nullsoft
  InstallerUrl: https://example.test/machine.exe
  InstallerSwitches:
    Silent: /S
  InstallerSuccessCodes:
  - 3010
  Scope: machine
License: Microsoft Software License
ManifestType: merged
PackageIdentifier: Microsoft.VisualStudioCode
PackageName: Microsoft Visual Studio Code
PackageVersion: 1.145.2
Publisher: Microsoft Corporation
ReleaseDate: 2026-11-06
ShortDescription: Microsoft Visual Studio Code is a code editor redefined and optimized
  for building and debugging modern web and cloud applications.
Tags:
- developer-tools
- editor
Agreements:
- AgreementLabel: EULA
  AgreementUrl: https://example.test/eula
"""
VERSIONS = """sV: 1.0
vD:
- v: 1.145.2
  rP: manifests/m/Microsoft/VisualStudioCode/1.145.2/7b94
  s256H: 3F129382EEF5D321B77F9038D5B6D9109840658141BA9E562E8E3BBA91B85550
- v: 1.144.0
  rP: manifests/m/Microsoft/VisualStudioCode/1.144.0/d666
  s256H: 3526fdd13d247ab338b943e3779921dac21ed5bbb5808da7c12c822113f498c9
"""

compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if compiler and os.uname().sysname == 'Darwin':
    with tempfile.TemporaryDirectory(prefix='madeira-winget-') as d:
        t = Path(d)
        db = sqlite3.connect(t / 'index.db')
        db.executescript("""
        CREATE TABLE packages(rowid INTEGER PRIMARY KEY, id TEXT NOT NULL, name TEXT NOT NULL, moniker TEXT, latest_version TEXT NOT NULL, arp_min_version TEXT, arp_max_version TEXT, hash BLOB);
        CREATE TABLE tags2(rowid INTEGER PRIMARY KEY, tag TEXT NOT NULL);
        CREATE TABLE tags2_map(tag INT64 NOT NULL, package INT64 NOT NULL, PRIMARY KEY(tag, package)) WITHOUT ROWID;
        CREATE TABLE commands2(rowid INTEGER PRIMARY KEY, command TEXT NOT NULL);
        CREATE TABLE commands2_map(command INT64 NOT NULL, package INT64 NOT NULL, PRIMARY KEY(command, package)) WITHOUT ROWID;
        """)
        rows = [(1, 'Microsoft.VisualStudioCode', 'Microsoft Visual Studio Code', 'vscode', '1.145.2'),
                (2, 'VSCodium.VSCodium', 'VSCodium', None, '1.2.3'),
                (3, 'Foo.Editor', 'Foo Editor', 'fooed', '9'),
                (4, 'Notepad.Plus', 'Notepad++', 'npp', '8'),
                (5, 'Percent.Tool', '100% Tool', None, '1')]
        for r in rows:
            db.execute('INSERT INTO packages(rowid,id,name,moniker,latest_version,hash) VALUES(?,?,?,?,?,?)', (*r, bytes([r[0]]) * 32))
        db.execute("INSERT INTO tags2 VALUES(1,'vscode-like')")
        db.execute('INSERT INTO tags2_map VALUES(1,3)')
        db.execute("INSERT INTO commands2 VALUES(1,'code')")
        db.execute('INSERT INTO commands2_map VALUES(1,1)')
        db.commit(); db.close()
        raw = VERSIONS.encode()
        comp = zlib.compressobj(wbits=-15); deflated = comp.compress(raw) + comp.flush()
        (t / 'versionData.mszyml').write_bytes(b'\x0aQ\xe5\xc0' + b'\0' * 24 + b'CK' + deflated)
        (t / 'manifest.yaml').write_text(MANIFEST)
        (t / 'plain.bin').write_bytes(b'abc')
        (t / 'system.reg').write_text('''WINE REGISTRY Version 2
[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Foo] 1700000000
"DisplayName"="Foo App"
"DisplayVersion"="1.0"
"InstallLocation"="C:\\\\Program Files\\\\Foo"
"UninstallString"="\\"C:\\\\Program Files\\\\Foo\\\\unins000.exe\\" /SILENT"
"EstimatedSize"=dword:00000001

[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Foo\\\\Sub] 1
"DisplayName"="not a program"

[Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Bar] 1700000001
"DisplayName"="Bar Tool"
"DisplayVersion"="2.0"

[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\{G-1}] 1700000002
"DisplayName"="Other Thing"
"Publisher"="Acme"

[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run] 1
"X"="y"
''')
        main = r'''
import Foundation
var bad = 0
func expect(_ c: Bool, _ l: String) { if !c { print("FAIL:", l); bad += 1 } }
let dir = CommandLine.arguments[1]
guard let index = WingetIndex(path: dir + "/index.db") else { print("FAIL: open"); exit(1) }
expect(index.count == 5, "five packages")
expect(WingetIndex(path: dir + "/plain.bin") == nil, "a non-index file is refused")
let code = index.search("vscode").map(\.id)
expect(code.first == "Microsoft.VisualStudioCode" && code.contains("Foo.Editor"), "moniker match first, tag match found: \(code)")
expect(index.search("code").map(\.id).first == "VSCodium.VSCodium" || index.search("code").first?.id == "Microsoft.VisualStudioCode", "substring names rank")
expect(index.search("100%").map(\.id) == ["Percent.Tool"], "LIKE characters are literal")
expect(index.search("a").isEmpty, "one character is not a search")
expect(index.package(id: "Foo.Editor")?.hash == String(repeating: "03", count: 32), "hash is hex")
let exact = WingetPackage(id: "x.y", name: "VSCode", moniker: "", latest: "1", hash: "")
let part = WingetPackage(id: "x.z", name: "My VSCode Pack", moniker: "", latest: "1", hash: "")
expect(WingetIndex.score(exact, "vscode") > WingetIndex.score(part, "vscode"), "exact beats substring")
let vd = try! Data(contentsOf: URL(fileURLWithPath: dir + "/versionData.mszyml"))
let versions = WingetVersionData.decode(vd)
expect(versions?.count == 2 && versions?[0].version == "1.145.2" && versions?[0].path.hasSuffix("/7b94") == true, "versionData decodes")
expect(versions?[0].sha256 == "3f129382eef5d321b77f9038d5b6d9109840658141ba9e562e8e3bba91b85550", "hash lower-cased")
expect(WingetVersionData.decode(Data("nonsense".utf8)) == nil, "garbage is refused")
let m = WingetManifest.parse(try! String(contentsOfFile: dir + "/manifest.yaml", encoding: .utf8))
expect(m?.id == "Microsoft.VisualStudioCode" && m?.name == "Microsoft Visual Studio Code" && m?.version == "1.145.2", "ids")
expect(m?.shortDescription.hasPrefix("Microsoft Visual Studio Code is a code editor") == true && m?.shortDescription.hasSuffix("web and cloud applications.") == true, "folded scalar joins")
expect(m?.tags == ["developer-tools", "editor"], "tags")
expect(m?.iconURL == "https://example.test/a.png", "png icon preferred")
expect(m?.installers.count == 2, "two installers (a list at its key's indent)")
let a = m?.installers[0], b = m?.installers[1]
expect(a?.type == "inno" && a?.scope == "user" && a?.architecture == "x64" && a?.switches["Custom"] == "/mergetasks=!runcode", "top-level defaults apply")
expect(b?.type == "nullsoft" && b?.switches["Silent"] == "/S" && b?.switches["Custom"] == "/mergetasks=!runcode" && b?.successCodes == [3010], "installer overrides and merges switches")
expect(a?.sha256 == "706ba8b326d87637a923676076eb2936060be6de5c0ae4691b3f76d2cac54f08", "installer hash lower-cased")
expect(m?.agreements.first?.label == "EULA", "agreements")
expect(wingetSHA256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256")
expect(WingetManifest.parse("nonsense") == nil && WingetManifest.parse("") == nil, "not a manifest")

func inst(_ type: String, arch: String = "x64", scope: String? = nil, sw: [String: String] = [:], nested: String? = nil, nestedFiles: [String] = []) -> WingetInstaller {
    var i = WingetInstaller(); i.type = type; i.architecture = arch; i.scope = scope; i.switches = sw; i.nestedType = nested; i.nestedFiles = nestedFiles; i.url = "https://example.test/Setup-1.2"; return i
}
func choice(_ l: [WingetInstaller]) -> (WingetInstaller, WingetStep)? { if case .success(let c) = WingetPlan.choose(l) { return (c.installer, c.step) }; return nil }
func refusal(_ l: [WingetInstaller]) -> WingetRefusal? { if case .failure(let r) = WingetPlan.choose(l) { return r }; return nil }
expect(choice([inst("inno", arch: "arm64"), inst("inno", arch: "x64")])?.0.architecture == "x64", "x64 over arm64")
expect(refusal([inst("inno", arch: "arm64")]) == .onlyArm, "only arm is refused")
expect(refusal([]) == .noInstaller, "no installer")
expect(choice([inst("inno", arch: "x86"), inst("inno", arch: "x64")])?.0.architecture == "x64", "x64 over x86")
expect(choice([inst("inno", scope: "machine"), inst("inno", scope: "user")])?.0.scope == "user", "user scope first")
expect(choice([inst("burn"), inst("nullsoft")])?.0.type == "nullsoft", "burn last")
expect(choice([inst("inno")])?.1 == .installer(arguments: "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"), "inno defaults")
expect(choice([inst("nullsoft", sw: ["Custom": "/D=x"])])?.1 == .installer(arguments: "/S /D=x"), "nullsoft with custom")
expect(choice([inst("wix")])?.1 == .msi(arguments: "/quiet /norestart"), "wix is msi")
expect(choice([inst("msi", sw: ["Silent": "/qn"])])?.1 == .msi(arguments: "/qn"), "manifest silent wins")
expect(refusal([inst("exe")]) == .needsSilentSwitch, "bare exe needs a switch")
expect(choice([inst("exe", sw: ["Silent": "-q"])])?.1 == .installer(arguments: "-q"), "exe with silent")
expect(refusal([inst("msix")]) == .packaged("msix"), "msix refused")
expect(choice([inst("portable")])?.1 == .portable, "portable")
expect(choice([inst("zip", nested: "portable", nestedFiles: ["a/b.exe"])])?.1 == .archive(nested: "a/b.exe", then: .portable), "zip with portable inside")
expect(choice([inst("zip", nested: "msi", nestedFiles: ["x.msi"])])?.1 == .archive(nested: "x.msi", then: .msi(arguments: "/quiet /norestart")), "zip with msi inside")
expect(refusal([inst("zip")]) == .noNestedFile, "zip without nested file")
expect(choice([inst("exe"), inst("inno", arch: "x86")])?.0.type == "inno", "usable installer beats refused one")
expect(WingetPlan.fileName(for: inst("msi")) == "Setup-1.2.msi" && WingetPlan.fileName(for: inst("inno")) == "Setup-1.2.exe", "file names get an extension")
expect(WingetPlan.folderName("A/B:C") == "A_B_C", "folder names")
expect(WingetPlan.isNewer("1.10", than: "1.9") && !WingetPlan.isNewer("1.2", than: "1.2.0") && WingetPlan.isNewer("2", than: "1.9.9"), "versions compare by number")
let plainURL = URL(fileURLWithPath: dir + "/plain.bin")
expect(WingetPlan.sha256Hex(ofFile: plainURL) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "file hash streams")
let reg = try! String(contentsOfFile: dir + "/system.reg", encoding: .utf8)
let entries = WingetRegistry.uninstallEntries(reg)
expect(entries.count == 3, "three uninstall entries: \(entries.keys.sorted())")
expect(entries["64|Foo"]?.name == "Foo App" && entries["64|Foo"]?.location == "C:\\Program Files\\Foo" && entries["64|Foo"]?.uninstall == "\"C:\\Program Files\\Foo\\unins000.exe\" /SILENT", "values unescaped")
expect(entries["32|Bar"]?.version == "2.0" && entries["64|{G-1}"]?.publisher == "Acme", "wow64 view and guid keys")
let added = WingetRegistry.added(before: Set(["64|Foo"]), after: entries, name: "Bar Tool")
expect(added.map(\.key).first == "32|Bar" && added.count == 2, "only new keys, best name first: \(added.map(\.key))")
expect(WingetRegistry.driveCRelative("\"C:\\Program Files\\Foo\\a.exe\"") == "Program Files/Foo/a.exe" && WingetRegistry.driveCRelative("D:\\x") == nil, "windows path to drive_c")
let q1 = WingetRegistry.splitCommand("\"C:\\Program Files\\Foo\\unins000.exe\" /SILENT")
expect(q1?.program == "C:\\Program Files\\Foo\\unins000.exe" && q1?.arguments == "/SILENT", "quoted uninstall command")
let q2 = WingetRegistry.splitCommand("MsiExec.exe /X{AAAA-BBBB}")
expect(q2?.program == "MsiExec.exe" && q2?.arguments == "/X{AAAA-BBBB}", "msiexec uninstall command")
let q3 = WingetRegistry.splitCommand("C:\\Foo\\u.exe /S")
expect(q3?.program == "C:\\Foo\\u.exe" && q3?.arguments == "/S" && WingetRegistry.splitCommand("") == nil, "plain uninstall command")
exit(bad == 0 ? 0 : 1)
'''
        (t / 'main.swift').write_text(main)
        (t / 'WingetCore.swift').write_text(core)
        (t / 'WingetPlan.swift').write_text(plan)
        subprocess.run([compiler, str(t / 'WingetCore.swift'), str(t / 'WingetPlan.swift'), str(t / 'main.swift'), '-o', str(t / 'wg')], check=True)
        check(subprocess.run([str(t / 'wg'), str(t)]).returncode == 0, 'Swift fixture')
elif args.require_swift:
    check(False, 'swiftc on macOS is required')
else:
    print('SKIP: no swiftc on macOS, source checks only')
raise SystemExit(1 if failures else 0)
