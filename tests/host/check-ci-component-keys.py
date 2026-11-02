#!/usr/bin/env python3
"""Check selective invalidation against the workflow's actual cache recipes."""
from pathlib import Path
from itertools import combinations
import fnmatch
import hashlib
import json
import re

root = Path(__file__).resolve().parents[2]
workflow = (root / '.github/workflows/build.yml').read_text()
assert 'restore-keys:' not in workflow, 'cache reuse must use exact input keys'
parts = re.split(r'^  ([a-z0-9_-]+):\n', workflow.split('jobs:\n', 1)[1], flags=re.M)
jobs = dict(zip(parts[1::2], parts[2::2]))
cache_lines = {name: re.findall(r'^          key: (.+)$', block, re.M) for name, block in jobs.items()}
recipes = {name: re.search(r'run: echo "key=([^"\n]+)"', jobs[name])[1] for name in ['fex', 'i386']}
templates = {name: cache_lines[name][0] for name in ['llvm', 'fex', 'i386']}
for name, marker in [('mingw', 'mingw-'), ('gnutls', '-gnutls-'), ('ffmpeg', '-ffmpeg-'),
                     ('freetype', '-freetype-'), ('rppairing', '-rppairing-'),
                     ('wine-host', '-wine-host-'), ('dxmt', '-dxmt-ios-')]:
    matches = [line for line in cache_lines['app'] if marker in line.split('${{ hashFiles', 1)[0]]
    assert len(matches) == 1, (name, matches)
    templates[name] = matches[0]
assert templates['mingw'] in cache_lines['i386'], 'both MinGW consumers must use the same cache'

# Expected dependency edges are independent of the workflow expressions.
cases = {
    'app': ('app/Madeira/Main.swift', {'ipa'}),
    'fex': ('pin:FEX', {'fex', 'ipa'}),
    'wine': ('pin:wine', {'wine-host', 'i386', 'dxmt', 'ipa'}),
    'dxmt': ('pin:dxmt', {'i386', 'dxmt', 'ipa'}),
    'dxmt-patches': ('build/dxmt-patches/0001-d3d9-index-range-per-draw.patch', {'i386', 'dxmt', 'ipa'}),
    'llvm': ('tools/build/build-llvm-ios.sh', {'llvm', 'dxmt', 'ipa'}),
    'mingw': ('tools/build/setup-llvm-mingw.sh', {'mingw', 'wine-host', 'i386', 'ipa'}),
    'crypto': ('build/gnutls-ios/build.sh', {'gnutls', 'ipa'}),
    'media': ('build/ffmpeg/src/ffmpeg-7.1.1.tar.xz', {'ffmpeg', 'ipa'}),
    'fonts': ('build/freetype-ios/build.sh', {'freetype', 'ipa'}),
    'rust': ('build/rppairing-ios/src/lib.rs', {'rppairing', 'ipa'}),
    'shaders': ('tools/build/build-shader-headers.sh', {'i386', 'dxmt', 'ipa'}),
    'converter': ('madeira-d3d12/src/unix/madeira_ir_unix.mm', {'dxmt', 'ipa'}),
    'crypto-source': ('build/gnutls-ios/src/gnutls-3.8.9.tar.xz', {'gnutls', 'ipa'}),
    'font-wrapper': ('tools/build/build-freetype-ios.sh', {'freetype', 'ipa'}),
    'rust-lock': ('build/rppairing-ios/Cargo.lock', {'rppairing', 'ipa'}),
    'rust-notices': ('build/rppairing-ios/notices.py', {'rppairing', 'ipa'}),
    'rust-build': ('build/rppairing-ios/build.rs', {'rppairing', 'ipa'}),
    'cargo-config': ('.cargo/config.toml', {'rppairing', 'ipa'}),
    'rust-toolchain': ('rust-toolchain.toml', {'rppairing', 'ipa'}),
    'fex-inner-recipe': ('build/fex-ios/build.sh', {'fex', 'ipa'}),
    'docs': ('BUILDING.md', {'ipa'}),
    'workflow': ('.github/workflows/build.yml', {'ipa'}),
}
files = {path: path for path, _ in cases.values() if not path.startswith('pin:')}
pins = {name: name for name in ['FEX', 'wine', 'dxmt']}
hash_expression = re.compile(r'\$\{\{\s*hashFiles\((.*?)\)\s*\}\}')
variable = re.compile(r'\$\{\{\s*([\w.]+)\s*\}\}')


def keys(changed):
    source, versions = dict(files), dict(pins)
    for name in changed:
        path, _ = cases[name]
        if path.startswith('pin:'):
            versions[path[4:]] += '-changed'
        else:
            source[path] += '-changed'

    def evaluate(text, job):
        text = re.sub(r'\$\(git rev-parse HEAD:([^)]+)\)', lambda m: versions[m[1]], text)

        def recipe_hash(match):
            patterns = re.findall(r"'([^']+)'", match[1])
            selected = sorted(path for path in source if any(fnmatch.fnmatchcase(path, p) for p in patterns))
            # Test declared input coverage; GitHub owns the cache hash implementation.
            return hashlib.sha256(json.dumps([(p, source[p]) for p in selected]).encode()).hexdigest()

        text = hash_expression.sub(recipe_hash, text)
        values = {'runner.os': 'macOS', 'runner.arch': 'ARM64', 'steps.sdk.outputs.key': 'native',
                  'steps.sdk.outputs.rust': 'rust', 'steps.sdk.outputs.graphics': 'graphics',
                  'steps.sdk.outputs.ipa': 'ipa-env', 'steps.pins.outputs.wine': versions['wine'],
                  'steps.pins.outputs.dxmt': versions['dxmt']}

        def replace(match):
            name = match[1]
            if name == 'steps.key.outputs.key':
                return evaluate(recipes[job], job)
            if name in ['needs.fex.outputs.key', 'needs.i386.outputs.key']:
                producer = name.split('.')[1]
                return evaluate(recipes[producer], producer)
            return values[name]

        text = variable.sub(replace, text)
        assert '${{' not in text and '$(' not in text, text
        return text

    result = {name: evaluate(template, name) for name, template in templates.items()}
    result['ipa'] = hashlib.sha256(json.dumps([source, versions], sort_keys=True).encode()).hexdigest()
    for name in ['llvm', 'fex', 'i386']:
        assert result[name] == evaluate(cache_lines['app'][['llvm', 'fex', 'i386'].index(name)], 'app'), name
    return result


baseline = keys([])
dimensions = list(cases)[:12]
count = 0
selections = [tuple([name]) for name in cases]
selections += [chosen for size in range(len(dimensions) + 1) for chosen in combinations(dimensions, size)]
for chosen in selections:
    current = keys(chosen)
    actual = {name for name in baseline if baseline[name] != current[name]}
    expected = set().union(*(cases[name][1] for name in chosen))
    assert actual == expected, (chosen, actual, expected)
    count += 1
print(f'PASS: {count} individual and combined source changes invalidate only their dependent caches')
