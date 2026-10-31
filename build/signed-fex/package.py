#!/usr/bin/env python3
"""Build a small LiveContainer guest using Madeira's production signed FEX runner."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import zipfile

here = Path(__file__).resolve().parent
root = here.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = here / 'out/device'
app = out / 'Payload/MadeiraSignedFEX.app'
app.mkdir(parents=True, exist_ok=True)
framework = here / 'out/iphoneos/MadeiraSignedFEX.framework'
assert framework.is_dir(), 'Build the iphoneos bundle first'
shutil.copytree(framework, app / 'Frameworks/MadeiraSignedFEX.framework', dirs_exist_ok=True)
sources = [here / 'device.m', root / 'app/Madeira/SignedFEX.c', root / 'app/Madeira/SignedCodeProbe.m']
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios17.0', '-isysroot', sdk,
    '-O2', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-I', str(root / 'app/Madeira'),
    *[str(p) for p in sources], '-framework', 'UIKit', '-framework', 'Foundation',
    '-o', str(app / 'MadeiraSignedFEX')], check=True)
inputs = [*sources, here / 'bridge.S', here / 'support.c', here / 'workload.c', here / 'out/translated.bin',
    here / 'out/guest-image.bin', here / 'out/metadata.json', root / 'app/Madeira/SignedFEX.h']
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source_id = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
provenance = {'source_id': source_id, 'sha256': hashes,
    'fex_revision': json.loads((here / 'out/metadata.json').read_text())['fex_revision']}
(app / 'source-info.json').write_text(json.dumps(provenance, indent=2) + '\n')
info = {'CFBundleIdentifier': 'com.madeira.signed-fex.program', 'CFBundleName': 'Madeira Signed FEX',
    'CFBundleDisplayName': 'Madeira Signed FEX', 'CFBundleExecutable': 'MadeiraSignedFEX',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'MinimumOSVersion': '17.0', 'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1, 2],
    'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True, 'UILaunchScreen': {},
    'MadeiraFEXSourceID': source_id,
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
            'UISceneConfigurationName': 'FEX', 'UISceneDelegateClassName': 'MadeiraFEXScene'}]}}}
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in app.rglob('*'):
        if path.is_file(): archive.write(path, path.relative_to(out))
with zipfile.ZipFile(args.output) as archive:
    assert archive.testzip() is None
    assert 'Payload/MadeiraSignedFEX.app/Info.plist' in archive.namelist()
print(args.output.resolve())
print('source-id=' + source_id)
print('ipa-sha256=' + hashlib.sha256(args.output.read_bytes()).hexdigest())
