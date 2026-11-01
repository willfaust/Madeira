#!/usr/bin/env python3
"""LocalDevVPN loopback check and the Madeira JIT shortcut (app/Madeira/JITNetwork.swift);
no device runs.

1. Swift: compiles the production LoopbackProbe on the host, pointed at local test
   listeners, and checks the route step (it names the interface traffic leaves by, and
   a listener reached other than through a VPN does not count and is never connected
   to, which is how a network that accepts any connection is ruled out) and the
   connection step (a listening port connects in milliseconds, a closed port fails at
   once).
2. Source checks: Enable JIT checks the loopback before any JIT method and runs the
   shortcut only when it does not answer and the shortcut is turned on; "start" asks for
   the cellular step only when Madeira sees cellular data without Wi-Fi, and "done" undoes
   only what "start" changed; the restore runs after the debugger detached and before
   Wine starts; the app hands madeira://jit-network/... to the shortcut; Settings has the
   switch.
"""
from pathlib import Path
import json, os, shutil, socket, subprocess, sys, tempfile, threading

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


net = (app / 'JITNetwork.swift').read_text()
setup = (app / 'JITSetup.swift').read_text()
content = (app / 'ContentView.swift').read_text()
main_app = (app / 'MadeiraApp.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()

# ------------------------------------------------------------------ static
require('/* JITNetwork.swift in Sources */,' in project, 'JITNetwork.swift is built by the Xcode project')
require('static let address = "10.7.0.1"' in net and 'static let port: UInt16 = 62078' in net,
        "the check targets lockdownd through LocalDevVPN's loopback (10.7.0.1:62078, StikDebug's address)")
enable = setup[setup.index('    func enable(interactive: Bool = true, completion:'):setup.index('    private func enableResolved(')]
require(enable.index('ensureLoopback') < enable.index('self?.enableResolved'),
        'Enable JIT checks the loopback before any JIT method')
ensure = enable[enable.index('private func ensureLoopback('):]
require('guard !probe.reachable else { proceed(false); return }' in ensure
        and 'guard JITNetworkShortcut.shared.enabled else {' in ensure
        and 'LocalDevVPNControl.shared.connect' in ensure,
        'unreachable loopback connects LocalDevVPN directly unless the user selected the shortcut')
require('JITNetworkShortcut.shared.restoreIfNeeded' in enable,
        'a JIT attempt that fails after the shortcut ran puts back what it changed')
start = net[net.index('    func start(completion:'):net.index('    /// From the launch thread')]
require('let cellular = cellularOnly' in start
        and start.index('pending = base') < start.index('run(cellular ? "start cellular" : "start")')
        and 'guard let input = pending else { completion(); return }' in start and 'run(input)' in start and 'if restoring { restoreWaiters.append(completion); return }' in start,
        '"start" asks for the cellular step only without Wi-Fi, and records the "done" it owes before it runs')
require('self?.pending = base + (vpnWasOn ? " vpn-restore" : " vpn-off")' in start
        and 'if case .done(let output) = outcome, !localDevVPNWasUp' in start,
        '"done" disconnects LocalDevVPN when no VPN was on, restores the one the shortcut kept, '
        'and leaves VPNs alone when LocalDevVPN was already on or "start" did not report')
require('Save File' not in net and 'Get File' not in net,
        'the shortcut needs no file (no iCloud Drive or folder to set up)')
require('returned output=\\(result.isEmpty ? "none" : "a VPN name")' in net and 'vpn-restore\\n' not in net,
        "Madeira neither logs nor keeps the VPN's name (the shortcut keeps the VPN itself)")

# The bundled shortcut: a signed export (iOS imports only signed files), in the app's
# resources, named after the shortcut Madeira runs, offered on iOS 27 or later.
onboarding = (app / 'Onboarding.swift').read_text()
bundled = app / 'Madeira JIT.shortcut'
blob = bundled.read_bytes() if bundled.exists() else b''
require(blob[:4] == b'AEA1' and b'SigningCertificateChain' in blob[:64],
        'Madeira JIT.shortcut is a signed export (AEA1 with a signing certificate chain)')
require('/* Madeira JIT.shortcut in Resources */,' in project,
        'Madeira JIT.shortcut is copied into the app')
require('Bundle.main.url(forResource: "Madeira JIT", withExtension: "shortcut")' in net
        and 'static let name = "Madeira JIT"' in net,
        "the file's name is the shortcut's name Madeira runs (Shortcuts names an import after its file)")
require('OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)' in net
        and 'if shortcut.enabled, JITShortcutFile.supported, let url = JITShortcutFile.url {' in setup,
        'the shortcut is offered on iOS 27 or later only (it uses Store Content)')
require('JITQuickSetup { if model.step == .jit { model.next() } }' in onboarding and 'shortcutPage' not in onboarding
        and 'private func finishJIT() { model.next() }' in onboarding,
        "setup uses one direct JIT action; alternate methods finish without a shortcut page")
require('struct JITShortcutAdvanced: View' in setup
        and 'UIApplication.shared.open(JITShortcutFile.iCloudLink)' in setup
        and 'ShareLink("Import a local copy", item: url)' in setup,
        "the optional shortcut remains available under advanced settings")
require('static let iCloudLink = URL(string: "https://www.icloud.com/shortcuts/' in net
        and 'THE TWO MUST BE THE SAME SHORTCUT' in net,
        'the iCloud link and the bundled file are kept as one shortcut')
require("Keychain" in onboarding and "stays in Madeira's Documents folder" not in onboarding,
        "setup no longer says the pairing file is in Documents")

# ------------------------------------------------------------------ Swift
probe = net[net.index('enum LoopbackProbe {'):net.index('/// The user\'s "Madeira JIT" shortcut')]
probe = probe.replace('static let address = "10.7.0.1"', 'static var address = "10.7.0.1"') \
             .replace('static let port: UInt16 = 62078', 'static var port: UInt16 = 62078')
main = r'''
let args = CommandLine.arguments
LoopbackProbe.address = args[1]
LoopbackProbe.port = UInt16(args[2])!
let r = LoopbackProbe.check(timeout: 0.4, requireVPN: args[3] == "1")
let route = LoopbackProbe.route()
print("{\"reachable\": \(r.reachable), \"ms\": \(r.milliseconds), \"detail\": \"\(r.detail)\", \"interface\": \"\(route?.interface ?? "-")\", \"vpn\": \(route?.isVPN ?? false), \"ldv\": [\(LoopbackProbe.Route(interface: "utun5", address: "10.7.1.1").isLocalDevVPN), \(LoopbackProbe.Route(interface: "utun5", address: "172.19.0.1").isLocalDevVPN), \(LoopbackProbe.Route(interface: "en0", address: "10.7.1.1").isLocalDevVPN)]}")
'''


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 'main.swift'
    src.write_text('import Darwin\nimport Foundation\n' + probe + '\n' + main)
    exe = Path(tmp) / 'probe'
    build = subprocess.run([SWIFTC, '-O', str(src), '-o', str(exe)], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-3000:])
        require(False, 'the production LoopbackProbe compiles on the host')
    else:
        def run(addr, port, require_vpn):
            out = subprocess.run([str(exe), addr, str(port), '1' if require_vpn else '0'],
                                 capture_output=True, text=True, timeout=10).stdout
            return json.loads(out)

        srv = socket.socket()
        srv.bind(('127.0.0.1', 0))
        srv.listen(8)
        threading.Thread(target=lambda: [srv.accept()[0].close() for _ in range(8)], daemon=True).start()
        port = srv.getsockname()[1]
        up = run('127.0.0.1', port, False)
        require(up['reachable'] and up['ms'] < 100, 'a listening port connects in %.1f ms (%s)' % (up['ms'], up['detail']))
        require(up['interface'].startswith('lo') and up['vpn'] is False,
                'the route check names the interface traffic leaves by (%s), and lo0 is not a VPN' % up['interface'])
        held = run('127.0.0.1', port, True)
        require(not held['reachable'] and held['ms'] < 50 and 'not a VPN' in held['detail'],
                'a listener that accepts, reached other than through a VPN, does not count, and is never connected to (%.1f ms, %s)'
                % (held['ms'], held['detail']))
        refused = run('127.0.0.1', free_port(), False)
        require(not refused['reachable'] and refused['ms'] < 100,
                'a closed port fails at once (%.1f ms, %s)' % (refused['ms'], refused['detail']))
        require(up['ldv'] == [True, False, False],
                "LocalDevVPN is told from another VPN by its tunnel address: utun5 10.7.1.1 is LocalDevVPN; "
                "utun5 172.19.0.1 (a VPN carrying all traffic) and en0 are not")
        srv.close()

print('\n%s' % ('ALL PASS' if failures == 0 else '%d FAILURE(S)' % failures))
sys.exit(0 if failures == 0 else 1)
