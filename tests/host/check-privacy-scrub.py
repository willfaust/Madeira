#!/usr/bin/env python3
"""PrivacyScrub (app/Madeira/PrivacyScrub.swift): personal details out of shared text.

Runs every rule, in the app's order and with its hints, on sample lines shaped
like the ones in logs players posted in Discord (Oct 30 - Nov 5, 2026):
  * personal details are replaced: e-mail and public IP addresses, MAC
    addresses, the app's container path, home and Windows user folders,
    Steam IDs, Epic's sign-in code and account name, tokens and passwords;
  * what a fix needs is kept: loopback, LAN and LocalDevVPN addresses, version
    numbers, Wine's own user names, memory addresses, Windows error codes.
The patterns are ICU (NSRegularExpression); the ones used here mean the same
in Python's re.

Optional: pass log files or folders to scrub them and report anything that
still looks personal (used on the Discord logs; not part of the default run).
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/PrivacyScrub.swift').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


rule_re = re.compile(
    r'Rule\("([a-z0-9-]+)", hints: \[(.*?)\],\s*#"(.*?)"#,\s*"([^"]*)"(, caseInsensitive: true)?(?:, minLength: (\d+))?\)', re.S)
rules = []
for name, hints, pattern, template, ci, min_length in rule_re.findall(source):
    hint_list = re.findall(r'"((?:[^"\\]|\\.)*)"', hints)
    hint_list = [h.replace('\\\\', '\\') for h in hint_list]
    try:
        regex = re.compile(pattern, re.I if ci else 0)
    except re.error as e:
        check(False, f'rule {name} compiles ({e})')
        continue
    rules.append((name, hint_list, regex, template, int(min_length or 0)))

declared = re.findall(r'// RULE ([a-z0-9-]+)', source)
check(len(rules) == len(declared) and len(rules) >= 14,
      f'every rule was read from the Swift source ({len(rules)} read, {len(declared)} declared)')


# A rule's minLength (lines shorter skip it) must not exceed the shortest text it matches.
for name, hints, regex, template, min_length in rules:
    shortest = {'ipv4': '1.2.3.4', 'ipv6-full': '1:2:3:4:5:6:7:8', 'mac': '00:11:22:33:44:55', 'long-hex': 'a' * 48}.get(name)
    if min_length:
        check(shortest is not None and len(shortest) == min_length and regex.search(shortest) is not None,
              f'rule {name}: minLength {min_length} is its shortest match')


def expand(template):
    return lambda m: re.sub(r'\$(\d)', lambda g: m.group(int(g.group(1))) or '', template)


def scrub(line):
    lower = line.lower()
    for name, hints, regex, template, min_length in rules:
        if len(line.encode()) < min_length:
            continue
        if hints and not any(h in lower for h in hints):
            continue
        new = regex.sub(expand(template), line)
        if new != line:
            line, lower = new, new.lower()
    return line


# (input, text that must be gone, text that must remain)
removed = [
    ('[steam] signed in as somebody@example.com ok', 'somebody@example.com', 'signed in as'),
    ('connect to 84.17.33.201:27036 failed', '84.17.33.201', ':27036 failed'),
    ('peer 2a02:6b8:a::12:fe2 port 443', '2a02:6b8:a::12:fe2', 'port 443'),
    ('peer 2001:0db8:85a3:0000:0000:8a2e:0370:7334 up', '2001:0db8:85a3:0000:0000:8a2e:0370:7334', ' up'),
    ('wifi bssid=3c:22:fb:12:ab:9e', '3c:22:fb:12:ab:9e', 'bssid='),
    ("[main-exe] open_dll_file('/var/mobile/Containers/Data/Application/C4650DA9-9FB4-4B3E-93A8-B20433D25453/Documents/x.dll')",
     'C4650DA9-9FB4-4B3E-93A8-B20433D25453', '<app>/Documents/x.dll'),
    ('/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-0000-4111-8222-ABCDEFABCDEF/cache', '0A1B2C3D-0000-4111-8222-ABCDEFABCDEF', '/cache'),
    (r'image=L"C:\users\Tyler\AppData\Local\Temp\setup.exe"', 'Tyler', r'C:\users\<user>\AppData'),
    (r'cmdline=L"C:\\users\\mythic\\AppData\\Local\\Temp\\infinst.exe"', 'mythic', r'C:\\users\\<user>\\AppData'),
    ('loading /Users/jsmith/Library/Prefix/drive_c/game.exe', 'jsmith', '/Users/<user>/Library'),
    ('drive_c/users/Tyler/Documents/My Games', 'Tyler', 'drive_c/users/<user>/Documents'),
    ('/AppData/Roaming/Glaiel Games/Mewgenics/76561198012345678/logs/debug.txt', '76561198012345678', '/logs/debug.txt'),
    ('steamid [U:1:52079950] connected', '52079950', '[U:1:<steam-id>]'),
    ('owner STEAM_0:1:26039975', '26039975', 'owner '),
    (r'PlayGTAV.exe\" -AUTH_LOGIN=unused -AUTH_PASSWORD=4f0e8c7a1b2d43c5a6e7f8091a2b3c4d -AUTH_TYPE=exchange',
     '4f0e8c7a1b2d43c5a6e7f8091a2b3c4d', '-AUTH_TYPE=exchange'),
    ('-epicenv=Prod -EpicPortal -epicusername=CoolGamer99 -epicuserid=5db9a1c2e3f4 -epiclocale=en', 'CoolGamer99', '-epiclocale=en'),
    ('-epicuserid=5db9a1c2e3f4a5b6 -epiclocale=en', '5db9a1c2e3f4a5b6', '-epiclocale=en'),
    ('\t"AccountName"\t\t"cool_gamer"', 'cool_gamer', '"AccountName"'),
    ('\t"PersonaName"\t\t"Cool Gamer Guy"', 'Cool Gamer Guy', '"PersonaName"'),
    ('{"refresh_token": "abc.def.ghi-123", "expires": 3600}', 'abc.def.ghi-123', '"expires": 3600'),
    ('Authorization: Bearer ya29.a0AfH6SMBx-Long_Token', 'ya29.a0AfH6SMBx-Long_Token', 'Authorization'),
    ('id_token eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r', 'eyJhbGciOiJSUzI1NiJ9', 'id_token'),
    ('GET https://bob:hunter2@cdn.example.net/file', 'hunter2', 'https://<login>@cdn.example.net'),
    ('Logging in user \'cool_gamer\' to Steam Public...', 'cool_gamer', 'to Steam Public'),
    ('ticket blob 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef end', '0123456789abcdef0123456789abcdef0123456789abcdef', ' end'),
    ('apikey=AbC123dEf456GhI789jKl012MnO345pQr678StU9 ok', 'AbC123dEf456GhI789jKl012MnO345pQr678StU9', ' ok'),
]
for line, gone, kept in removed:
    out = scrub(line)
    check(gone not in out and kept in out, f'removed: {gone[:40]!r} -> {out[:110]!r}')

unchanged = [
    '[14:08:51.586] [INFO] [build] v0.2.0 (5)',
    '[14:08:51.586] [INFO] [device] model=iPhone18,1 idiom=phone os=iOS Version 27.0 (Build 24A437) ram=11722MB available=6106MB cores=6',
    '[jit-pool] EXHAUSTED (anon RWX): want=0xf88000 bump=0x151e8000/0x27548000 tail_resv=0x12008000 freelist=0',
    '0178:err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x132cf2913',
    'D 178 Exception: Code: C0000005 Address: 16D71C1B8 AV WRITE of 121C798F8',
    r'image=L"C:\users\mobile\AppData\Local\Temp\x.exe"',
    r'C:\\users\\steamuser\\Documents',
    '/users/mobile/AppData/Local',
    'listening on 127.0.0.1:27060',
    'LocalDevVPN tunnel 10.7.0.1 -> 10.7.1.1)',
    'lan peer 192.168.1.20 and 172.20.1.4',
    'SSDP 239.255.255.250:1900',
    'System.Runtime (6.0.0.0)',
    'mono v0.40.4.0 and v1.9.7.17 loaded',
    "'2.4.0.296' and 10.0.19041.1",
    '{00020400-0000-0000-C000-000000000046}',
    'Wine exited with code 0 at 04:46:12.123',
    '[dock-report] probe-result=0 launch-client-error=0 ticket=0',
    '-AUTH_LOGIN=unused -AUTH_TYPE=exchange',
    'session_id=1 token=none password=empty',
    'std::vector<int>::size and Face::Render',
    '[madeira-d3d12] CheckFeatureSupport(feature 48, 40 bytes) refused: not implemented (x4)',
    'wine: Call from 00000001601F5C9C to unimplemented function COMCTL32.dll.345, aborting',
    'game-cfg MADEIRA_JIT_POOL_MB=1024 pool-split = 1',
    'module=L"EOSSDK-Win64-Shipping-1.17.1.3.dll" base=00000073C',
    'PS_VehicleTextured_Eight_2217dd95_Wrapped and $s7Madeira44F996987440283C1BLL7profileyAA12LibraryEntryVSg_tFyyYbcfU4_',
    'dump 000000000000000000000000000000000000000000000100000002000000',
    '[WineProc] argv[6] = -AUTH_PASSWORD=<redacted>',
]
for line in unchanged:
    out = scrub(line)
    check(out == line, f'kept as is: {line[:70]!r}' + ('' if out == line else f' -> {out[:110]!r}'))

check('rule.hints.isEmpty || rule.hints.contains(where: { lower.contains($0) })' in source,
      'a rule runs only on lines that hold one of its hints (most lines of a big log skip every regex)')
check('if buffer.count >= 1 << 20' in source and 'read(upToCount: 1 << 20)' in source,
      'a scrubbed copy is read and written in 1 MB pieces')

# Optional: scrub real logs and list what still looks personal.
if len(sys.argv) > 1:
    leaks = {'email': re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}'),
             'container': re.compile(r'/Containers/[A-Za-z/]+/[0-9A-F]{8}-'),
             'steam-id': re.compile(r'7656119\d{10}'),
             'win-user': re.compile(r'(?i)users\\+(?!mobile|steamuser|public|default|all users|<user>)\w+'),
             'secret': re.compile(r'(?i)(password|exchangecode|epicusername)=(?!<hidden>|<redacted>|unused)\S+')}
    files = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        files += [f for f in p.rglob('*.txt')] if p.is_dir() else [p]
    found = {}
    for f in files:
        with open(f, 'rb') as fh:
            for raw in fh:
                out = scrub(raw.decode('utf-8', 'replace').rstrip('\r\n'))
                for k, r in leaks.items():
                    for m in r.findall(out):
                        found.setdefault(k, set()).add(m if isinstance(m, str) else m[0])
    for k in leaks:
        print(f'LEAK-CHECK {k}: {len(found.get(k, ()))} distinct left in {len(files)} files')

print('PASS' if failures == 0 else f'FAIL ({failures})')
sys.exit(1 if failures else 0)
