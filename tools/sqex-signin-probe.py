#!/usr/bin/env python3
"""Run Madeira's Square Enix sign-in from a Mac, against the real servers.

Compiles app/Madeira/SquareEnixSignIn.swift with a small driver and signs in
once with the installation given (any FFXIV program in it, or its folder):
login and gate status, the boot check, the login page, the credentials and the
session registration (docs/SQUARE_ENIX_SIGNIN.md, steps 1 to 6). It prints the
sign-in's own log lines, which hold no secrets, and the launch arguments with
the session ID masked. The game is not started.

The password and one-time password are read without echo and reach the driver
on its standard input, never in its arguments or environment. A refused
sign-in is never retried: repeated wrong passwords can lock the account.

  python3 tools/sqex-signin-probe.py --game "<.../FINAL FANTASY XIV - A Realm Reborn>" --license mac --region 2
"""
from pathlib import Path
import argparse
import getpass
import re
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
parser.add_argument('--game', required=True, help='the game folder (holding boot/ and game/) or one of its programs')
parser.add_argument('--license', choices=['mac', 'windows'], required=True)
parser.add_argument('--region', type=int, required=True, help='rgn of the login page')
parser.add_argument('--language', default='en', help='lng of the login page (default en)')
parser.add_argument('--frontier-language', default='en-us', help='lang of the gate status (default en-us)')
parser.add_argument('--free-trial', action='store_true')
parser.add_argument('--install-id', help='the Windows User-Agent id (default: a new one per run)')
parser.add_argument('--patch-user-agent', help="override the license's patch User-Agent")
args = parser.parse_args()

if args.install_id:
    raw = bytes.fromhex(args.install_id) if re.fullmatch(r'[0-9a-f]{10}', args.install_id) else b''
    if len(raw) != 5 or sum(raw) % 256:
        sys.exit('--install-id: ten lowercase hex digits whose five bytes add up to a multiple of 256')

root = Path(__file__).resolve().parents[1]
game = Path(args.game).expanduser()
program = game if game.suffix.lower() == '.exe' else game / 'game/ffxiv_dx11.exe'

driver = r'''
import Foundation

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let install = FFXIVInstall(program: URL(fileURLWithPath: argument("--program")!)) else {
    print("Not an FFXIV installation (no boot/ffxivboot.ver and game/ffxivgame.ver beside the program).")
    exit(2)
}
var options = SquareEnixSignInOptions(license: SquareEnixLicense(rawValue: argument("--license")!)!,
                                      region: Int(argument("--region")!)!,
                                      installID: argument("--install-id") ?? SquareEnixSignInOptions.newInstallID())
options.language = argument("--language")!
options.frontierLanguage = argument("--frontier-language")!
options.freeTrial = argument("--free-trial") == "1"
options.patchUserAgent = argument("--patch-user-agent")

let id = readLine(strippingNewline: true) ?? ""
let password = readLine(strippingNewline: true) ?? ""
let oneTime = readLine(strippingNewline: true) ?? ""
let credentials = SquareEnixCredentials(id: id, password: password, oneTimePassword: oneTime)

let done = DispatchSemaphore(value: 0)
var status: Int32 = 0
Task {
    do {
        let launch = try await SquareEnixSignIn(log: { print($0) }).signIn(
            install: install, options: options, credentials: credentials, progress: { print("step: \($0.rawValue)") })
        print("RESULT: signed in; would start \(launch.program.path)")
        for argument in launch.arguments {
            print("  " + (argument.hasPrefix("DEV.TestSID=") ? "DEV.TestSID=<session ID, \(argument.count - 12) characters>" : argument))
        }
    } catch {
        print("RESULT: \(error)")
        print("  message: \(error.localizedDescription)")
        status = 1
    }
    done.signal()
}
done.wait()
exit(status)
'''

compiler = shutil.which('swiftc')
if not compiler:
    sys.exit('swiftc is needed (Xcode or the Swift toolchain).')
with tempfile.TemporaryDirectory(prefix='sqex-probe-') as directory:
    temporary = Path(directory)
    (temporary / 'main.swift').write_text(driver)
    binary = temporary / 'sqex-probe'
    subprocess.run([compiler, '-O', str(root / 'app/Madeira/SquareEnixSignIn.swift'), str(temporary / 'main.swift'),
                    '-o', str(binary)], check=True)

    sqexid = input('Square Enix ID: ')
    password = getpass.getpass('Password: ')
    one_time = getpass.getpass('One-time password (Enter for none): ')
    command = [str(binary), '--program', str(program), '--license', args.license, '--region', str(args.region),
               '--language', args.language, '--frontier-language', args.frontier_language,
               '--free-trial', '1' if args.free_trial else '0']
    if args.install_id:
        command += ['--install-id', args.install_id]
    if args.patch_user_agent:
        command += ['--patch-user-agent', args.patch_user_agent]
    result = subprocess.run(command, input=f'{sqexid}\n{password}\n{one_time}\n', text=True)
    sys.exit(result.returncode)
