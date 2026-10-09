#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 David Brookes
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Type-check Madeira's actual Swift source list without linking native archives.

Requires macOS and Xcode. This is NOT an app build or a native ABI check.
"""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
project = root / 'app/Madeira.xcodeproj/project.pbxproj'
objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))['objects']
target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Madeira')
phase = next(objects[i] for i in target['buildPhases'] if objects[i]['isa'] == 'PBXSourcesBuildPhase')
files = [root / 'app/Madeira' / objects[objects[i]['fileRef']]['path']
         for i in phase['files'] if objects[objects[i]['fileRef']].get('path', '').endswith('.swift')]
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'swiftc', '-typecheck', '-swift-version', '5', '-D', 'DEBUG',
                '-module-name', 'Madeira', '-sdk', sdk, '-target', 'arm64-apple-ios17.0',
                '-import-objc-header', str(root / 'app/Madeira/Madeira-Bridging-Header.h'),
                *map(str, files)], check=True)
print(f'PASS: {len(files)} production Swift sources type-check for iOS; native linking not tested')
