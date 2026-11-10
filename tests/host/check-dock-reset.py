#!/usr/bin/env python3
"""madeira-bcd: the Dock's "Reset one-time installs" (app/Madeira/DockReset.swift) and
the session of one-time installs (owner's decision 2026-10-12).

Source checks (every host):
  * the switches MADEIRA_DOCK_RESET_CLEAN and MADEIRA_DOCK_INSTALL_SEPARATE are read and
    listed in the config catalog;
  * a reset runs DockReset.clean before the records go; Reset and "Reset and sign out of
    Rockstar" are offered; the other games sharing the installs get Run at next start;
  * a start with pending installs runs only them (no host on the command line, no sign-in
    transfer left behind) and asks for a restart when the session ends;
  * the app reads the fresh prefix's registry from prefix-template.tar.gz through the
    bridging header; DockReset.swift is in the Xcode project.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the real
DockReset.swift against synthetic prefixes:
  * what moves into the backup: the Rockstar Games Launcher, Social Club, ProgramData,
    the Visual C++ Package Cache and cached packages, the Vulkan runtime, regular runtime
    files in system32/syswow64 (never Madeira's links, never other DLLs, never Steam's
    files or the game's), sign-in data only with sign-out;
  * system.reg: the chain's uninstall entries, Windows Installer registrations, Burn
    dependency keys, Rockstar keys and the Rockstar Service go; shared values go from
    UpgradeCodes and Components (a key left empty goes too, hex continuations with
    it); the VC++ markers get the template's values; Wine Mono, the games' own keys,
    older runtimes and the Steam run records stay; the file keeps Wine's format;
  * the backup holds the registry files as they were and a list;
  * the real prefix-template.tar.gz registry: nothing of the chain is found, and
    restoring its own VC++ markers from itself changes nothing;
  * Madeira's vulkan-1.dll stand-in (MADEIRA_DOCK_VULKAN_STANDIN): a Vulkan loader an
    installer wrote into system32 moves into the backup before a Dock start; Madeira's
    link stays, and nothing moves when the app has no stand-in.
"""
from pathlib import Path
import argparse, os, re, shutil, subprocess, sys, tarfile, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


reset = (app / 'DockReset.swift').read_text(encoding='utf-8')
installers = (app / 'DockInstallers.swift').read_text(encoding='utf-8')
content = (app / 'ContentView.swift').read_text(encoding='utf-8')
view = (app / 'MadeiraDockView.swift').read_text(encoding='utf-8')
dock = (app / 'MadeiraDock.swift').read_text(encoding='utf-8')
screen = (app / 'DockStartScreen.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
bridging = (app / 'Madeira-Bridging-Header.h').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
catalog = (app / 'ConfigCatalog.generated.swift').read_text(encoding='utf-8')

# ------------------------------------------------------------------ source checks
for switch in ('MADEIRA_DOCK_RESET_CLEAN', 'MADEIRA_DOCK_VULKAN_STANDIN',
               'MADEIRA_DOCK_INSTALL_LAYOUT'):
    check(f'flag("{switch}")' in installers, f'{switch} is read (default on, env.{switch} = 0 turns it off)')
    check(f'key: "env.{switch}"' in catalog, f'{switch} is in the config catalog')
prep = installers[installers.index('    static func prepare('):]
prep = prep[:prep.index('\n    }\n')]
check(prep.index('absorbResults(') < prep.index('DockReset.restoreStandIn(') < prep.index('guard enabled else'),
      "every Dock start, before its session, puts an installer's Vulkan loader out of system32")
check('appendingPathComponent("arm64ec-windows/vulkan-1.dll")' in prep, "only with Madeira's stand-in in the app")
check('installSessionDroppedKeys: Set<String> = ["env.MADEIRA_SC_PA_POOLS", "env.MADEIRA_RDR2_VA_HOLD"]' in installers,
      'a session of one-time installs leaves out only the two address-space holds that take the 32-bit slots')
check('setenv("MADEIRA_DOCK_INSTALLS_SESSION", "1", 1)' in content and 'unsetenv("MADEIRA_DOCK_INSTALLS_SESSION")' in content and
      content.index('profile.applyEnvironment()') < content.index('DockInstallers.applyInstallSessionConfig()'),
      'only an installs-only Dock start marks its session; the copy without them replaces the game file after the profile wrote it')
check('setenv("MADEIRA_CFG_GAME", copy.path, 1)' in installers and 'madeira-game-installs.cfg' in installers,
      'the session reads the copy (MADEIRA_CFG_GAME); the game\'s own file stays as it is')
check('case .reset?, .resetSignOut?:' in installers and 'DockReset.clean(drive: drive, prefix: prefix' in installers,
      'a reset (with or without sign-out) runs DockReset.clean')
check(installers.index('DockReset.clean(') < installers.index('changed = try SteamInstallScripts.unmark(runs'),
      'the installed components go before the records')
check('signOut: request == .resetSignOut' in installers, 'sign-out only for "Reset and sign out of Rockstar"')
check('case resetSignOut = "reset-signout"' in installers, 'the sign-out request has its own stored value')
m = re.search(r'static func shareReset\(.*?\n    \}\n', installers, re.S)
check(m is not None and 'alsoRun = shareReset(app, runs: runs, found: found, others: others, drive: drive, prefix: prefix, ledger: &ledger)' in installers,
      'a reset that removed the installs hands them to the other games')
check(m is not None and 'keys.contains(key(process.run)) || files.contains(file(process.executable))' in m.group(0) and
      'SteamInstallScripts.unmark(shared, prefix: prefix)' in m.group(0) and 'ledger.runNext[String(other.id)] = nil' in m.group(0),
      'another game recording under the same keys or running the same installer loses those records and gets Run at next start')
check('others: MadeiraDock.games(drive: MadeiraDock.drive)' in content, 'the Dock start passes the other games')
check('Button("Reset and sign out of Rockstar", role: .destructive) { dock.setInstallRequest(appID, .resetSignOut) }' in view,
      'the Reset dialog offers sign-out')
check('madeira-reset-backup' in view and 'madeira-reset-backup' in reset, 'the dialog names the backup folder')
check('installsOnly = separateSession()' in installers, 'only a start that writes a batch runs installs only')
# A session of its own only where it is needed: the setting (game's lines, then madeira.cfg, then the
# environment) decides when set; unset, only a game whose own lines hold a layout key does.
sep = installers[installers.index('nonisolated static func separateSession('):]
sep = sep[:sep.index('\n    }\n')]
check('let key = "env.MADEIRA_DOCK_INSTALL_SEPARATE"' in sep and 'game(key) ?? global(key)' in sep and
      'return set != "0"' in sep and 'return installSessionDroppedKeys.contains { game($0) != nil }' in sep,
      'MADEIRA_DOCK_INSTALL_SEPARATE: set wins; unset, only a game with an address-space layout line runs installs alone')
check('key: "env.MADEIRA_DOCK_INSTALL_SEPARATE"' in catalog, 'MADEIRA_DOCK_INSTALL_SEPARATE is in the config catalog')
check('host: !DockInstallers.installsOnly' in content, 'the session command line follows installsOnly')
m = re.search(r'static func launchArguments\(width: Int, height: Int, installers: String\? = nil, host: Bool = true\) -> String \{(.*?)\n    \}', dock, re.S)
check(m and 'guard host else { return "/desktop=madeira,\\(width)x\\(height) C:\\\\windows\\\\system32\\\\cmd.exe /c call \\(installers)" }' in m.group(1),
      'without the host the batch runs alone (no "& dockhost.exe")')
check(re.search(r'if DockInstallers\.installsOnly \{\s*// No host runs in this session: nothing will take the sign-in transfer\.\s*MadeiraDock\.cleanup\(\)', content) is not None,
      'an installs-only session leaves no sign-in transfer on disk')
check('LibraryModel.shared.restartNotice = DockInstallers.restartNotice(DockInstallers.poll(drive: MadeiraDock.drive))' in view and
      'LibraryModel.shared.restartNotice = DockInstallers.restartNotice(ended)' in view,
      'the end of an installs-only session asks for a restart')
check('if allSucceeded { return "One-time installs completed successfully. Close Madeira and open it again to play the game." }' in installers and
      'allSucceeded = total > 0 && succeeded == total' in installers and 'allSucceeded = false' in installers,
      'the alert in the owner\'s words when every install succeeded; otherwise the count and the failed ones')
check(re.search(r'if DockInstallers\.installsOnly, running, !offered, let finished = DockInstallers\.finishedAt,\s*'
                r'Date\(\)\.timeIntervalSince\(finished\) >= 45 \{\s*offered = true', view) is not None,
      'a session an installer\'s program keeps open: the restart is offered 45 s after the installs (after a registry save)')
check('restartHint: DockInstallers.installsOnly\n' in library and
      '? (model.installsRestartReady ? DockInstallers.closeWords : DockInstallers.closingWords) : nil)' in library and
      'if let restartHint { return' in screen,
      'the starting screen says the session closes (no restart before Wine has saved the registry)')
# The starting screen's Close Madeira: 45 s after the batch, by its own poll, so it needs neither
# the report watch nor the alert; both of the watch's restart paths set it too.
check('MainActor.assumeIsolated { (DockInstallers.installsOnly, DockInstallers.finishedAt) }' in screen and
      'if installsOnly, !model.installsRestartReady, let finished = installsFinished,' in screen and
      'Date().timeIntervalSince(finished) >= 45' in screen and view.count('LibraryModel.shared.installsRestartReady = true') == 2 and
      library.count('if model.installsRestartReady {') == 4 and 'installsRestartReady = false' in library,  # 2 old layouts + new look
      'the starting screen offers Close Madeira 45 s after the installs (after a registry save)')
check('restartWords' not in library and 'restartWords' not in screen, 'only the end of the session asks for the restart')
check('nonisolated static let restartWords' in installers and 'nonisolated static let closingWords' in installers,
      'the restart and closing words can be read outside the main actor')
check('DockReset.baselineProvider = { DockReset.templateRegistry { madeira_extract_prefix_tgz($0, $1) } }' in content,
      'the app reads the fresh prefix registry from the bundled template')
check('#include "PrefixExtractor.h"' in bridging, 'the template extractor is visible to Swift')
check(sum('DockReset.swift' in line for line in project.splitlines()) == 4 and 'path = DockReset.swift;' in project,
      'DockReset.swift is in the Xcode project (file, build file, group, sources)')
check('Bundle.main.path(forResource: "prefix-template", ofType: "tar.gz")' in reset, 'the template comes from the app bundle')
check('steamapps' in reset and '!lower.hasPrefix("program files (x86)/steam")' in reset, 'nothing of Steam is ever a target')
check('moveItem(at:' in reset and 'removeItem(at: drive' not in reset and 'removeItem(atPath' not in reset,
      'files move into the backup, nothing under drive_c is deleted')

# ------------------------------------------------------------------ Swift fixture
MONO = '{0591009C-75D7-5F33-B5DF-4F47111155EC}'
BUNDLE = '{11111111-2222-3333-4444-555566667777}'
PRODUCT = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
X86 = '{12345678-9ABC-DEF0-1234-56789ABCDEF0}'


def packed(guid):
    h = guid.strip('{}').replace('-', '').upper()
    return h[0:8][::-1] + h[8:12][::-1] + h[12:16][::-1] + ''.join(h[i + 1] + h[i] for i in range(16, 32, 2))


assert packed(MONO) == 'C90019507D5733F55BFDF474111155CE'   # the template's Wine Mono product key
PP, PX, PM = packed(PRODUCT), packed(X86), packed(MONO)


def esc(path):
    return path.replace('\\', '\\\\')


def key(path, *values):
    return '[' + esc(path) + '] 1776969660\n#time=1dcd350bb5ffc5e\n' + ''.join(v + '\n' for v in values) + '\n'


def sz(name, value):
    return '"' + name + '"="' + esc(value) + '"'


HEADER = 'WINE REGISTRY Version 2\n;; All keys relative to REGISTRY\\\\Machine\n\n#arch=win64\n\n'
RUNTIME = lambda version: ['"Installed"=dword:00000001', sz('Version', version)]
UNINSTALL = 'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\'
UNINSTALL32 = 'Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\'
USERDATA = 'Software\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\'
DEPS = 'Software\\Classes\\Installer\\Dependencies\\'

system_reg = HEADER + ''.join([
    key('Software\\Classes\\Installer\\Dependencies\\Microsoft.VS.VC_RuntimeMinimumVSU_amd64,v14', sz('Version', '14.40')),
    key(DEPS + 'Microsoft.VS.VC_RuntimeMinimumVSU_amd64,v14\\Dependents\\' + BUNDLE),
    key(DEPS + 'VC,redist.x64,amd64,14.40,bundle', sz('DisplayName', 'Microsoft Visual C++ 2015-2022 Redistributable (x64)')),
    key(DEPS + 'Microsoft.VS.VC_RuntimeMinimumVSU_amd64,v12', sz('Version', '12.0')),
    key(DEPS + MONO, sz('Version', '10.4.1')),
    key('Software\\Classes\\Installer\\Features\\' + PP, '"Runtime"=""'),
    key('Software\\Classes\\Installer\\Products\\' + PM, sz('ProductName', 'Wine Mono Windows Support')),
    key('Software\\Classes\\Installer\\Products\\' + PP, sz('ProductName', 'Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.40.33810')),
    key('Software\\Classes\\Installer\\Products\\' + PP + '\\SourceList', sz('PackageName', 'vc_runtimeMinimum_x64.msi')),
    key('Software\\Classes\\Installer\\Products\\' + PX, sz('ProductName', 'Microsoft Visual C++ 2022 X86 Additional Runtime - 14.40.33810')),
    key('Software\\Classes\\Installer\\UpgradeCodes\\00000000000000000000000000000001', '"' + PP + '"=""', '"' + PM + '"=""'),
    key('Software\\Classes\\Installer\\UpgradeCodes\\00000000000000000000000000000002', '"' + PP + '"=""'),
    key(UNINSTALL + 'Rockstar Games Launcher', sz('DisplayName', 'Rockstar Games Launcher'),
        sz('InstallLocation', 'C:\\Program Files\\Rockstar Games\\Launcher')),
    key(UNINSTALL + PRODUCT, sz('DisplayName', 'Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.40.33810'),
        '"WindowsInstaller"=dword:00000001', '"SystemComponent"=dword:00000001'),
    key(USERDATA + 'Components\\00000000000000000000000000000C01', '"' + PP + '"="C:\\\\windows\\\\system32\\\\msvcp140.dll"',
        '"' + PM + '"="C:\\\\windows\\\\mono\\\\x.dll"'),
    key(USERDATA + 'Components\\00000000000000000000000000000C02',
        '"' + PP + '"=hex(2):43,00,3a,00,5c,00,77,00,69,00,6e,00,64,00,6f,00,77,00,73,00,5c,00,\\',
        '  73,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,00,00'),
    key(USERDATA + 'Products\\' + PP + '\\InstallProperties', sz('LocalPackage', 'C:\\windows\\Installer\\abc123.msi')),
    key(USERDATA + 'Products\\' + PP + '\\Features', '"Runtime"=""'),
    key('Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64', *RUNTIME('14.40.33810.0')),
    key('Software\\Rockstar Games\\Launcher', sz('InstallFolder', 'C:\\Program Files\\Rockstar Games\\Launcher')),
    key('Software\\Rockstar Games\\Red Dead Redemption 2', sz('InstallFolderSteam', 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Red Dead Redemption 2')),
    key('Software\\Rockstar Games\\Steam\\SDK', '"240240"=dword:00000001'),
    key('Software\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x86', *RUNTIME('14.40.33810.0')),
    key(UNINSTALL32 + BUNDLE, sz('DisplayName', 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.40.33810'),
        sz('BundleCachePath', 'C:\\ProgramData\\Package Cache\\' + BUNDLE + '\\VC_redist.x64.exe'),
        sz('BundleProviderKey', 'VC,redist.x64,amd64,14.40,bundle')),
    key(UNINSTALL32 + MONO, sz('DisplayName', 'Wine Mono Windows Support'), '"WindowsInstaller"=dword:00000001'),
    key(UNINSTALL32 + 'VulkanRT1.1.108.0', sz('DisplayName', 'Vulkan Run Time Libraries 1.1.108.0')),
    key(UNINSTALL32 + '{22222222-0000-0000-0000-000000000013}', sz('DisplayName', 'Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664')),
    key('Software\\Wow6432Node\\Rockstar Games\\Rockstar Games Social Club', sz('InstallFolder', 'C:\\Program Files\\Rockstar Games\\Social Club')),
    key('System\\CurrentControlSet\\Services\\Rockstar Service',
        '"ImagePath"=str(2):"' + esc('C:\\Program Files\\Rockstar Games\\Launcher\\RockstarService.exe') + '"'),
    key('System\\CurrentControlSet\\Services\\Rockstar Service\\Parameters', '"x"=dword:00000001'),
    key('System\\CurrentControlSet\\Services\\Spooler', '"ImagePath"=str(2):"' + esc('C:\\windows\\system32\\spoolsv.exe') + '"'),
])
template_reg = HEADER + ''.join([
    key('Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64', *RUNTIME('14.42.34433.0')),
    key('Software\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64', *RUNTIME('14.42.34433.0')),
    key('Software\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x86', *RUNTIME('14.42.34433.0')),
])
user_reg = HEADER.replace('Machine', 'User\\\\S-1-5-21-0-0-0-1000') + ''.join([
    key('Software\\Rockstar Games\\Launcher', sz('Language', 'en-US')),
    key('Software\\Rockstar Games\\Red Dead Redemption 2', '"x"=dword:00000001'),
])

FILES = [
    'Program Files/Rockstar Games/Launcher/Launcher.exe',
    'Program Files/Rockstar Games/Social Club/socialclub.dll',
    'ProgramData/Rockstar Games/Launcher/service_log.txt',
    'ProgramData/Package Cache/' + BUNDLE + '/VC_redist.x64.exe',
    'ProgramData/Package Cache/' + PRODUCT + 'v14.40.33810/packages/vc_runtimeMinimum_x64.msi',
    'ProgramData/Package Cache/' + X86 + 'v14.40.33810/packages/vc_runtimeAdditional_x86.msi',
    'ProgramData/Package Cache/{99999999-0000-0000-0000-000000000000}/other.exe',
    'Program Files (x86)/vulkanrt/uninstall.exe',          # another case than DockReset.folders
    'windows/system32/msvcp140.dll',
    'windows/system32/vulkan-1.dll',
    'windows/system32/kernel32.dll',
    'windows/syswow64/mfc140u.dll',
    'windows/syswow64/notes.txt',
    'windows/Installer/abc123.msi',
    'Program Files (x86)/Steam/steamapps/common/Red Dead Redemption 2/RDR2.exe',
    'Program Files (x86)/Steam/msvcp140.dll',
    'users/mobile/AppData/Local/Rockstar Games/Launcher/settings.json',
    'users/mobile/AppData/Local/Rockstar Games/GTA V/cache.bin',
    'users/mobile/Documents/Rockstar Games/Social Club/Profiles/p.dat',
    'users/mobile/Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml',
    'users/Public/Documents/Rockstar Games/Launcher/x.txt',
]
MOVED = {
    'Program Files/Rockstar Games/Launcher', 'Program Files/Rockstar Games/Social Club',
    'ProgramData/Rockstar Games', 'Program Files (x86)/vulkanrt',
    'ProgramData/Package Cache/' + BUNDLE, 'ProgramData/Package Cache/' + PRODUCT + 'v14.40.33810',
    'ProgramData/Package Cache/' + X86 + 'v14.40.33810',
    'windows/system32/msvcp140.dll', 'windows/system32/vulkan-1.dll', 'windows/syswow64/mfc140u.dll',
    'windows/Installer/abc123.msi',
}
SIGNED_OUT = {'users/mobile/AppData/Local/Rockstar Games/Launcher', 'users/mobile/Documents/Rockstar Games/Social Club'}

main_swift = r'''
import Foundation
let env = ProcessInfo.processInfo.environment
if env["MADEIRA_TEST_MODE"] == "standin" {
    let moved = DockReset.restoreStandIn(drive: URL(fileURLWithPath: env["MADEIRA_TEST_DRIVE"]!, isDirectory: true),
                                         documents: URL(fileURLWithPath: env["MADEIRA_TEST_DOCUMENTS"]!, isDirectory: true),
                                         standIn: URL(fileURLWithPath: env["MADEIRA_TEST_STANDIN"]!),
                                         now: Date(timeIntervalSince1970: 1_791_800_000))
    print("moved=" + (moved ?? "nil"))
    exit(0)
}
let prefix = URL(fileURLWithPath: env["MADEIRA_TEST_PREFIX"]!, isDirectory: true)
let documents = URL(fileURLWithPath: env["MADEIRA_TEST_DOCUMENTS"]!, isDirectory: true)
let baselinePath = env["MADEIRA_TEST_BASELINE"] ?? ""
let baseline: String? = baselinePath.isEmpty ? nil : (try? String(contentsOfFile: baselinePath, encoding: .utf8))
let summary = DockReset.clean(drive: prefix.appendingPathComponent("drive_c", isDirectory: true), prefix: prefix,
                              documents: documents, appID: 1174180, signOut: env["MADEIRA_TEST_SIGNOUT"] == "1",
                              baseline: baseline, now: Date(timeIntervalSince1970: 1_791_800_000))
var out = ["backup=" + summary.backup, "keys=\(summary.keys)", "values=\(summary.values)", "restored=\(summary.restored)"]
out += summary.moved.map { "moved=" + $0 }
out += summary.entries.map { "entry=" + $0 }
out += summary.failures.map { "failure=" + $0 }
out.append("packed=" + (DockReset.packed("{0591009C-75D7-5F33-B5DF-4F47111155EC}") ?? "nil"))
out.append("unpacked=" + (DockReset.unpacked("C90019507D5733F55BFDF474111155CE") ?? "nil"))
out.append("packed-name=" + (DockReset.packed("Rockstar Games Launcher") ?? "nil"))
for name in ["Rockstar Games Launcher", "Rockstar Games Social Club", "Microsoft Visual C++ 2015-2022 Redistributable (x86) - 14.40.33810",
             "Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.40.33810", "Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664",
             "Wine Mono Windows Support", "Red Dead Redemption 2", "Vulkan Run Time Libraries 1.1.108.0"] {
    out.append("chain=" + name + "=" + (DockReset.isChain(name) ? "1" : "0"))
}
print(out.joined(separator: "\n"))
'''


def sections(text):
    """{lowercased path: [value lines]} of a .reg text, plus whether every line has Wine's form."""
    result, current, valid = {}, None, True
    for index, line in enumerate(text.split('\n')):
        if line.startswith('['):
            if not re.match(r'^\[.*\] \d+$', line):
                valid = False
            current = line[1:line.rindex(']')].replace('\\\\', '\\').lower()
            result[current] = []
        elif current is None or line == '' or line.startswith('#'):
            continue
        elif line.startswith('"') or line.startswith('@=') or line.startswith('  '):
            result[current].append(line)
        else:
            valid = False
    return result, valid


def run(binary, base, signout, baseline=True, system=system_reg, user=user_reg, files=FILES):
    prefix = base / 'Documents/wine'
    drive = prefix / 'drive_c'
    for f in files:
        (drive / f).parent.mkdir(parents=True, exist_ok=True)
        (drive / f).write_text('x')
    (drive / 'windows/system32').mkdir(parents=True, exist_ok=True)
    target = base / 'Madeira.app/arm64ec-windows/vcruntime140.dll'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('builtin')
    os.symlink(target, drive / 'windows/system32/vcruntime140.dll')          # Madeira's own: a link
    (prefix / 'system.reg').write_text(system)
    (prefix / 'user.reg').write_text(user)
    (base / 'template.reg').write_text(template_reg)
    env = dict(os.environ, MADEIRA_TEST_PREFIX=str(prefix), MADEIRA_TEST_DOCUMENTS=str(base / 'Documents'),
               MADEIRA_TEST_BASELINE=str(base / 'template.reg') if baseline else '', MADEIRA_TEST_SIGNOUT='1' if signout else '0')
    out = subprocess.run([str(binary)], env=env, capture_output=True, text=True, check=True).stdout
    lines = out.strip().split('\n')
    values = {}
    for line in lines:
        k, _, v = line.partition('=')
        values.setdefault(k, []).append(v)
    return prefix, drive, values


with tempfile.TemporaryDirectory(prefix='madeira-dock-reset-') as directory:
    temporary = Path(directory)
    compiler = shutil.which('swiftc')
    if not compiler:
        if args.require_swift:
            raise SystemExit('Swift compiler required for the Dock reset fixture')
        print('SKIP: Swift compiler unavailable locally; macOS CI runs this check with --require-swift')
    else:
        (temporary / 'main.swift').write_text(main_swift)
        binary = temporary / 'dockreset'
        subprocess.run([compiler, '-swift-version', '5', str(app / 'DockReset.swift'), str(temporary / 'main.swift'),
                        '-o', str(binary)], check=True)

        # 1. Reset without sign-out.
        base = temporary / 'one'
        prefix, drive, out = run(binary, base, signout=False)
        check(out['packed'] == ['C90019507D5733F55BFDF474111155CE'] and out['unpacked'] == [MONO] and out['packed-name'] == ['nil'],
              'product codes pack and unpack like Windows Installer (Wine Mono, as in the template)')
        chain = dict(v.rsplit('=', 1) for v in out['chain'])
        check([chain[n] for n in sorted(chain)] == ['0', '1', '1', '0', '1', '1', '1', '0'],
              'the chain: Rockstar, VC++ 2015-2022 and Vulkan; not VC++ 2013, Wine Mono or a game')
        check(out.get('failure') is None, 'no failures')
        # macOS volumes ignore case: compare paths without it.
        lower = lambda paths: {p.lower() for p in paths}
        moved = lower(out.get('moved', []))
        check(moved == lower(MOVED), 'moved exactly the chain (got %s)' % sorted(moved ^ lower(MOVED)))
        backup = base / 'Documents' / out['backup'][0]
        check(out['backup'][0] == 'madeira-reset-backup/' + backup.name and backup.name.endswith('-app1174180'),
              'the backup folder is in Documents/madeira-reset-backup, named by time and app')
        check(all((backup / 'drive_c' / m).exists() and not (drive / m).exists() for m in MOVED),
              'each moved path is in the backup and gone from drive_c')
        kept = ['windows/system32/kernel32.dll', 'windows/syswow64/notes.txt',
                'ProgramData/Package Cache/{99999999-0000-0000-0000-000000000000}/other.exe',
                'Program Files (x86)/Steam/steamapps/common/Red Dead Redemption 2/RDR2.exe', 'Program Files (x86)/Steam/msvcp140.dll',
                'users/mobile/AppData/Local/Rockstar Games/Launcher/settings.json',
                'users/mobile/Documents/Rockstar Games/Social Club/Profiles/p.dat',
                'users/mobile/Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml']
        check(all((drive / k).exists() for k in kept), 'other DLLs, other caches, Steam, the game and (without sign-out) sign-in data stay')
        check((drive / 'windows/system32/vcruntime140.dll').is_symlink(), "Madeira's own runtime link stays")
        check((backup / 'system.reg').read_text() == system_reg and (backup / 'user.reg').read_text() == user_reg,
              'the backup holds both registry files as they were')
        listing = (backup / 'reset.txt').read_text()
        check('Program Files/Rockstar Games/Launcher' in listing and 'Rockstar Games Launcher' in listing, 'the backup lists what moved')

        after, valid = sections((prefix / 'system.reg').read_text())
        check(valid and (prefix / 'system.reg').read_text().startswith('WINE REGISTRY Version 2\n'), "system.reg keeps Wine's format")
        gone = [UNINSTALL + 'Rockstar Games Launcher', UNINSTALL + PRODUCT, UNINSTALL32 + BUNDLE, UNINSTALL32 + 'VulkanRT1.1.108.0',
                'Software\\Classes\\Installer\\Products\\' + PP, 'Software\\Classes\\Installer\\Products\\' + PP + '\\SourceList',
                'Software\\Classes\\Installer\\Products\\' + PX, 'Software\\Classes\\Installer\\Features\\' + PP,
                USERDATA + 'Products\\' + PP + '\\InstallProperties', USERDATA + 'Products\\' + PP + '\\Features',
                DEPS + 'Microsoft.VS.VC_RuntimeMinimumVSU_amd64,v14', DEPS + 'Microsoft.VS.VC_RuntimeMinimumVSU_amd64,v14\\Dependents\\' + BUNDLE,
                DEPS + 'VC,redist.x64,amd64,14.40,bundle', 'Software\\Rockstar Games\\Launcher',
                'Software\\Wow6432Node\\Rockstar Games\\Rockstar Games Social Club',
                'System\\CurrentControlSet\\Services\\Rockstar Service', 'System\\CurrentControlSet\\Services\\Rockstar Service\\Parameters',
                'Software\\Classes\\Installer\\UpgradeCodes\\00000000000000000000000000000002',
                USERDATA + 'Components\\00000000000000000000000000000C02']
        check(all(g.lower() not in after for g in gone), 'the chain\'s keys are gone (left: %s)' % [g for g in gone if g.lower() in after])
        stay = [UNINSTALL32 + MONO, 'Software\\Classes\\Installer\\Products\\' + PM, DEPS + 'Microsoft.VS.VC_RuntimeMinimumVSU_amd64,v12',
                DEPS + MONO, UNINSTALL32 + '{22222222-0000-0000-0000-000000000013}', 'Software\\Rockstar Games\\Red Dead Redemption 2',
                'Software\\Rockstar Games\\Steam\\SDK', 'System\\CurrentControlSet\\Services\\Spooler']
        check(all(s.lower() in after for s in stay), 'Wine Mono, older runtimes, the game\'s key, the run records and other services stay')
        upgrade = after['software\\classes\\installer\\upgradecodes\\00000000000000000000000000000001']
        component = after[(USERDATA + 'Components\\00000000000000000000000000000C01').lower()]
        check(upgrade == ['"' + PM + '"=""'] and len(component) == 1 and component[0].startswith('"' + PM + '"'),
              'shared UpgradeCodes and Components keep the other product\'s value')
        check(out['values'] == ['4'], 'four values of the removed product went (two with their keys)')
        markers = after['software\\microsoft\\visualstudio\\14.0\\vc\\runtimes\\x64']
        check('"Version"="14.42.34433.0"' in markers and '"Version"="14.40.33810.0"' not in (prefix / 'system.reg').read_text(),
              'the VC++ markers have the template\'s values again')
        check('software\\wow6432node\\microsoft\\visualstudio\\14.0\\vc\\runtimes\\x64' in after and out['restored'] == ['3'],
              'every marker key of the template is back, in both views')
        check((prefix / 'user.reg').read_text() == user_reg, 'without sign-out user.reg is untouched')

        # 2. Reset and sign out.
        base = temporary / 'two'
        prefix, drive, out = run(binary, base, signout=True)
        moved = lower(out.get('moved', []))
        check(moved == lower(MOVED | SIGNED_OUT), 'sign-out also moves the launcher\'s and Social Club\'s sign-in data (got %s)' % sorted(moved ^ lower(MOVED | SIGNED_OUT)))
        check((drive / 'users/mobile/Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml').exists() and
              (drive / 'users/mobile/AppData/Local/Rockstar Games/GTA V/cache.bin').exists() and
              (drive / 'users/Public/Documents/Rockstar Games/Launcher/x.txt').exists(),
              'the games\' own settings and the Public folder stay')
        user_after, valid = sections((prefix / 'user.reg').read_text())
        check(valid and 'software\\rockstar games\\launcher' not in user_after and 'software\\rockstar games\\red dead redemption 2' in user_after,
              'user.reg loses the launcher\'s key, keeps the game\'s')

        # 3. No template: the VC++ markers stay as they are.
        base = temporary / 'three'
        prefix, drive, out = run(binary, base, signout=False, baseline=False)
        check('"Version"="14.40.33810.0"' in (prefix / 'system.reg').read_text() and out['restored'] == ['0'],
              'without a template the markers are left alone')

        # 4. The real template: nothing of the chain, its own markers unchanged.
        with tarfile.open(app / 'prefix-template.tar.gz') as archive:
            real = archive.extractfile('prefix/system.reg').read().decode('utf-8')
        template_reg = real
        base = temporary / 'four'
        prefix, drive, out = run(binary, base, signout=False, system=real, files=[])
        before, _ = sections(real)
        after, valid = sections((prefix / 'system.reg').read_text())
        check(out.get('entry') is None and out.get('moved') is None, 'a fresh prefix has nothing of the chain')
        check(valid and after == before and out['restored'] == ['3'],
              'the template\'s registry survives a reset unchanged (%d keys)' % len(before))

        # 5. Madeira's vulkan-1.dll stand-in: an installer's loader moves out, a link stays.
        def standin(base, regular, app_has_standin):
            drive = base / 'Documents/wine/drive_c'
            (drive / 'windows/system32').mkdir(parents=True, exist_ok=True)
            stand = base / 'Madeira.app/arm64ec-windows/vulkan-1.dll'
            stand.parent.mkdir(parents=True, exist_ok=True)
            if app_has_standin:
                stand.write_text('stand-in')
            if regular:
                (drive / 'windows/system32/vulkan-1.dll').write_text('khronos')
            else:
                os.symlink(stand, drive / 'windows/system32/vulkan-1.dll')
            env = dict(os.environ, MADEIRA_TEST_MODE='standin', MADEIRA_TEST_DRIVE=str(drive),
                       MADEIRA_TEST_DOCUMENTS=str(base / 'Documents'), MADEIRA_TEST_STANDIN=str(stand))
            out = subprocess.run([str(binary)], env=env, capture_output=True, text=True, check=True).stdout.strip()
            return drive, out
        drive, out = standin(temporary / 'five', regular=True, app_has_standin=True)
        kept = list((temporary / 'five/Documents/madeira-reset-backup').glob('*-vulkan-loader/drive_c/windows/system32/vulkan-1.dll'))
        check(out == 'moved=windows/system32/vulkan-1.dll' and not (drive / 'windows/system32/vulkan-1.dll').exists() and
              len(kept) == 1 and kept[0].read_text() == 'khronos',
              "an installer's Vulkan loader moves from system32 into the backup (got %s)" % out)
        drive, out = standin(temporary / 'six', regular=False, app_has_standin=True)
        check(out == 'moved=nil' and (drive / 'windows/system32/vulkan-1.dll').is_symlink(), "Madeira's own link stays")
        drive, out = standin(temporary / 'seven', regular=True, app_has_standin=False)
        check(out == 'moved=nil' and (drive / 'windows/system32/vulkan-1.dll').read_text() == 'khronos',
              'without the stand-in in the app the loader stays')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
