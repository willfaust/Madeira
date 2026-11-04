#!/usr/bin/env python3
"""[sc-rph] against the owner's real SocialClubHelper.exe, read as data only.

Set MADEIRA_SC_HELPER_EXE to one or more helper paths (os.pathsep-separated);
without it this test prints SKIP and passes. The binary is never committed and
never executed: Python maps its sections the way Wine's loader does (raw data,
zero fill to the section's page end) and the production guard and patch from
build/ntdll-unix/virtual_ios.c run on that byte copy with a real SHA-256.

Per supplied build (selected by its TimeDateStamp / SizeOfImage entry in
ios_sch_builds) it checks:
  - every guarded window's SHA-256 (hashlib), the CefApp vtable slots, the zero
    / RET + int3 destinations, and that no DIR64 relocation touches a guarded
    window, a hook, a destination or a zero range while the five vtable slots
    the guard reads are relocated;
  - no RUNTIME_FUNCTION (.pdata) covers a written destination, so the stubs in
    int3 padding and the .text tail sit outside every function;
  - the production patch at the preferred base and in a relocated view logs
    success and changes only the declared blobs, hooks, task and two vtable
    slots, with each hook a branch to its destination;
  - MADEIRA_SC_IPC_SPLIT=0 leaves every IPC blob and hook alone;
  - MADEIRA_SC_RENDER_HANDLER=0, MADEIRA_SC_CEF=0, another image name and a
    one-byte change in any guarded window each write nothing (a mismatch logs
    its reason).
"""
from pathlib import Path
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile

paths = [p for p in os.environ.get('MADEIRA_SC_HELPER_EXE', '').split(os.pathsep) if p]
if not paths:
    print('SKIP: set MADEIRA_SC_HELPER_EXE to a SocialClubHelper.exe to check it (never executed)')
    sys.exit(0)

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
IMAGE_BASE = 0x140000000


def define(name):
    return int(re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', native)[1], 0)


def value(token):
    return define(token) if token.startswith('IOS') else int(token, 16)


def table(name):
    start = native.index(' ' + name + '[] =')
    return native[start:native.index('\n};', start)]


def array_bytes(name):
    start = native.index('static const unsigned char ' + name + '[')
    body = native[start:native.index('};', start) + 2]
    return bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', body[body.index('{'):]))


def function(signature):
    start = native.index(signature)
    return native[start:native.index('\n}', start) + 2]


def build_tables():
    builds = re.search(r'ios_sch_builds\[\] =\n\{(.*?)\n\};', native, re.S)[1]
    out = []
    for index, prefix in enumerate(re.findall(r'\n    \{ (IOS_SCH\w*?)STAMP,', builds)):
        s = prefix[len('IOS_SCH'):-1]
        d = lambda macro, P=prefix: define(P + macro)
        code = [(value(m[1]), int(m[2], 16), bytes(int(x, 16) for x in re.findall(r'0x([\da-f]{2})', m[3])))
                for m in re.finditer(r'\{ (IOS_SCH\w+|0x[\da-f]+), (0x[\da-f]+),[^{]*\{([^}]*)\}',
                                     table('ios_sch%s_code' % s))]
        blobs = [(value(m[1]), array_bytes(m[2]), int(m[3], 16), int(m[4])) for m in re.finditer(
            r'\{ (IOS_SCH\w+), (ios_sch\w+), sizeof\(\2\),\s*(0|0xcc), ([01]),', table('ios_sch%s_blob' % s))]
        hooks = [(value(m[1]), value(m[2]), int(m[3]), int(m[4], 16), int(m[5])) for m in re.finditer(
            r'\{ (IOS_SCH\w+|0x[\da-f]+), (IOS_SCH\w+), (\d), (0x[\da-f]+), ([01]) \}', table('ios_sch%s_hook' % s))]
        zeros = [(value(m[1]), int(m[2])) for m in
                 re.finditer(r'\{ (IOS_SCH\w+), (\d+),', table('ios_sch%s_zero' % s))]
        assert code and blobs and hooks and zeros, prefix
        out.append(dict(index=index, prefix=prefix, stamp=d('STAMP'), size=d('SIZE'), code=code, blobs=blobs,
                        hooks=hooks, zeros=zeros, vt_browser=d('VT_BROWSER'), vt_renderer=d('VT_RENDERER'),
                        vt_rph=d('VT_RPH'), get_handler=d('GET_HANDLER'), get_null=d('GET_NULL'),
                        webkit=d('WEBKIT'), thunk=d('THUNK'), loop_init=d('LOOP_INIT'), task=d('TASK')))
    return out


class Image:
    """The helper's sections at their RVAs, as Wine's loader lays them out."""

    def __init__(self, path):
        raw = Path(path).read_bytes()
        e = struct.unpack_from('<I', raw, 0x3c)[0]
        assert raw[:2] == b'MZ' and raw[e:e + 4] == b'PE\0\0', 'not a PE image'
        self.machine, self.nsec, self.stamp = struct.unpack_from('<HHI', raw, e + 4)
        optsz = struct.unpack_from('<H', raw, e + 20)[0]
        o = e + 24
        self.magic = struct.unpack_from('<H', raw, o)[0]
        self.base = struct.unpack_from('<Q', raw, o + 24)[0]
        self.size, self.headers = struct.unpack_from('<II', raw, o + 56)
        self.dirs = [struct.unpack_from('<II', raw, o + 112 + 8 * i) for i in range(16)]
        self.secs = []
        self.img = bytearray(self.size)
        self.img[:self.headers] = raw[:self.headers]
        for i in range(self.nsec):
            s = o + optsz + 40 * i
            vs, va, rs, rp = struct.unpack_from('<IIII', raw, s + 8)
            ch = struct.unpack_from('<I', raw, s + 36)[0]
            self.secs.append((va, vs, rs, ch))
            n = min(rs, (vs + 0xfff) & ~0xfff)
            self.img[va:va + n] = raw[rp:rp + n]

    def relocs(self):
        va, size = self.dirs[5]
        out, p = [], va
        while p < va + size:
            page, block = struct.unpack_from('<II', self.img, p)
            if not block:
                break
            for k in range((block - 8) // 2):
                entry = struct.unpack_from('<H', self.img, p + 8 + 2 * k)[0]
                if entry >> 12 == 10:
                    out.append(page + (entry & 0xfff))
                else:
                    assert entry >> 12 == 0, 'only DIR64 relocations expected'
            p += block
        return out

    def functions(self):
        va, size = self.dirs[3]
        return [struct.unpack_from('<II', self.img, va + 12 * i) for i in range(size // 12)]


PRELUDE = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
typedef uint64_t ULONG64;
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
typedef uint16_t WCHAR;
typedef struct { WCHAR *Buffer; uint16_t Length; } UNICODE_STRING;
typedef struct {
    struct { uint16_t Machine, NumberOfSections; uint32_t TimeDateStamp; } FileHeader;
    struct { uint16_t Magic; uint32_t SizeOfImage; } OptionalHeader;
} IMAGE_NT_HEADERS;
typedef struct { uint32_t VirtualAddress; union { uint32_t VirtualSize; } Misc;
                 uint32_t SizeOfRawData, Characteristics; } IMAGE_SECTION_HEADER;
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_NT_OPTIONAL_HDR64_MAGIC 0x20b
#define IMAGE_SCN_MEM_EXECUTE 0x20000000
#define IMAGE_SCN_MEM_WRITE 0x80000000
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define CC_SHA256_DIGEST_LENGTH 32
static int ios_sc_cef_enabled(void) { const char *e = getenv("MADEIRA_SC_CEF"); return !(e && *e == '0'); }
/* FIPS 180-4 SHA-256, standing in for CommonCrypto's CC_SHA256. */
static unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *md)
{
    static const uint32_t k[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    uint32_t h[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    const unsigned char *p = data;
    uint64_t bits = (uint64_t)len * 8;
    size_t total = ((size_t)len + 9 + 63) & ~(size_t)63, off;
    for (off = 0; off < total; off += 64)
    {
        unsigned char block[64];
        uint32_t w[64], a, b, c, d, e, f, g, hh;
        int i;
        for (i = 0; i < 64; i++)
        {
            size_t at = off + i;
            block[i] = at < len ? p[at] : at == len ? 0x80 : at >= total - 8 ? (unsigned char)(bits >> (8 * (total - 1 - at))) : 0;
        }
        for (i = 0; i < 16; i++) w[i] = (uint32_t)block[4*i] << 24 | block[4*i+1] << 16 | block[4*i+2] << 8 | block[4*i+3];
#define R(x, n) ((x) >> (n) | (x) << (32 - (n)))
        for (i = 16; i < 64; i++)
            w[i] = w[i-16] + (R(w[i-15], 7) ^ R(w[i-15], 18) ^ (w[i-15] >> 3)) + w[i-7] +
                   (R(w[i-2], 17) ^ R(w[i-2], 19) ^ (w[i-2] >> 10));
        a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
        for (i = 0; i < 64; i++)
        {
            uint32_t t1 = hh + (R(e, 6) ^ R(e, 11) ^ R(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
            uint32_t t2 = (R(a, 2) ^ R(a, 13) ^ R(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
#undef R
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    for (int i = 0; i < 32; i++) md[i] = (unsigned char)(h[i / 4] >> (24 - 8 * (i % 4)));
    return md;
}
'''

DRIVER = r'''
static unsigned char *load(const char *path, size_t *size)
{
    FILE *f = fopen(path, "rb");
    assert(f && !fseek(f, 0, SEEK_END));
    *size = (size_t)ftell(f);
    rewind(f);
    unsigned char *p = mmap(NULL, *size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(p != MAP_FAILED && fread(p, 1, *size, f) == *size && !fclose(f));
    return p;
}
static void save(const char *path, const void *p, size_t size)
{
    FILE *f = fopen(path, "wb");
    assert(f && fwrite(p, 1, size, f) == size && !fclose(f));
}
/* argv: image, DIR64 RVA list, "preferred" | "view", image name, before, after */
int main(int argc, char **argv)
{
    size_t size, nrel;
    assert(argc == 7);
    unsigned char *image = load(argv[1], &size);
    uint32_t *rel = (uint32_t *)load(argv[2], &nrel);
    const unsigned char *pe = image + *(uint32_t *)(image + 0x3c);
    IMAGE_NT_HEADERS nt = {{ *(uint16_t *)(pe + 4), *(uint16_t *)(pe + 6), *(uint32_t *)(pe + 8) },
                           { *(uint16_t *)(pe + 24), *(uint32_t *)(pe + 24 + 56) }};
    const unsigned char *table = pe + 24 + *(uint16_t *)(pe + 20);
    IMAGE_SECTION_HEADER sec[32];
    assert(nt.FileHeader.NumberOfSections <= 32 && nt.OptionalHeader.SizeOfImage == size);
    for (int i = 0; i < nt.FileHeader.NumberOfSections; i++)
    {
        const unsigned char *s = table + 40 * i;
        sec[i] = (IMAGE_SECTION_HEADER){ *(uint32_t *)(s + 12), {*(uint32_t *)(s + 8)}, *(uint32_t *)(s + 16),
                                         *(uint32_t *)(s + 36) };
    }
    if (!strcmp(argv[3], "view"))
    {
        /* The directory applied at the view: the vtables then carry view pointers. */
        uint64_t delta = (uint64_t)(uintptr_t)image - 0x140000000ull;
        for (size_t i = 0; i < nrel / 4; i++) *(uint64_t *)(image + rel[i]) += delta;
    }
    else assert(!strcmp(argv[3], "preferred"));
    WCHAR path[64];
    size_t n = strlen(argv[4]);
    assert(n < 64);
    for (size_t i = 0; i < n; i++) path[i] = (unsigned char)argv[4][i];
    UNICODE_STRING name = {path, (uint16_t)(n * sizeof(WCHAR))};
    save(argv[5], image, size);
    fprintf(stderr, "view=0x%llx\n", (unsigned long long)(uintptr_t)image);
    fflush(stderr);
    ios_sc_render_handler_patch((char *)image, size, &nt, sec, &name);
    save(argv[6], image, size);
    return 0;
}
'''

region = native[native.index('#define IOS_SCH_IMAGE_BASE'):
                native.index('\n}', native.index('static void ios_sc_render_handler_patch(')) + 2]


def run(binary, folder, image, mode, env=None, name='C:\\Program Files\\Social Club\\SocialClubHelper.exe'):
    (folder / 'image.bin').write_bytes(image)
    result = subprocess.run([str(binary), str(folder / 'image.bin'), str(folder / 'relocs.bin'), mode, name,
                             str(folder / 'before.bin'), str(folder / 'after.bin')],
                            capture_output=True, text=True, timeout=60, env={**os.environ, **(env or {})})
    assert not result.returncode, result.stderr
    view = int(re.search(r'view=0x([\da-f]+)', result.stderr)[1], 16)
    return ((folder / 'before.bin').read_bytes(), (folder / 'after.bin').read_bytes(),
            result.stderr, view)


def changed(before, after):
    return [i for i in range(len(before)) if before[i] != after[i]] if before != after else []


def check_binary(path, builds, binary, folder):
    pe = Image(path)
    assert pe.machine == 0x8664 and pe.magic == 0x20b and pe.base == IMAGE_BASE, 'x64 image at the preferred base'
    matches = [b for b in builds if (b['stamp'], b['size']) == (pe.stamp, pe.size)]
    assert matches, 'TimeDateStamp 0x%08x SizeOfImage 0x%x is not an analysed build' % (pe.stamp, pe.size)
    build = matches[0]
    label = '%s (TimeDateStamp 0x%08x)' % (Path(path).name, pe.stamp)
    img = bytes(pe.img)

    # --- data checks, independent of the C guard -------------------------------
    for rva, n, digest in build['code']:
        assert hashlib.sha256(img[rva:rva + n]).digest() == digest, (label, hex(rva))
    q = lambda rva: struct.unpack_from('<Q', img, rva)[0]
    slot = lambda vt, i: q(vt + 8 * i)
    B, R = define('IOS_SCH_SLOT_BROWSER'), define('IOS_SCH_SLOT_RENDERER')
    assert slot(build['vt_browser'], B) == IMAGE_BASE + build['get_handler']
    assert slot(build['vt_browser'], R) == IMAGE_BASE + build['get_null']
    assert slot(build['vt_renderer'], R) == IMAGE_BASE + build['get_handler']
    assert slot(build['vt_renderer'], B) == IMAGE_BASE + build['get_null']
    assert q(build['vt_rph']) == IMAGE_BASE + build['webkit']
    for rva, code, fill, _ in build['blobs']:
        assert img[rva:rva + len(code)] == bytes([fill]) * len(code), (label, hex(rva), 'destination')
    for rva, n in build['zeros']:
        assert img[rva:rva + n] == bytes(n), (label, hex(rva), 'zero range')
    relocs = pe.relocs()
    hits = lambda lo, hi: [r for r in relocs if r < hi and r + 8 > lo]
    for rva, n, _ in build['code']:
        assert not hits(rva, rva + n), (label, hex(rva), 'relocation inside a guarded window')
    for rva, code, _, _ in build['blobs']:
        assert not hits(rva, rva + len(code)), (label, hex(rva), 'relocation inside a destination')
    for site, _, span, _, _ in build['hooks']:
        assert not hits(site, site + span), (label, hex(site), 'relocation inside a hook')
    for rva, n in build['zeros']:
        assert not hits(rva, rva + n), (label, hex(rva), 'relocation inside a zero range')
    for rva in (build['vt_browser'] + 8 * B, build['vt_browser'] + 8 * R, build['vt_renderer'] + 8 * B,
                build['vt_renderer'] + 8 * R, build['vt_rph']):
        assert rva in relocs, (label, hex(rva), 'the guard reads a relocated slot')
    for begin, end in pe.functions():
        for rva, code, _, _ in build['blobs']:
            assert end <= rva or begin >= rva + len(code), (label, hex(rva), 'destination inside a function')
    print('PASS: %s: %d SHA-256 windows, vtables, %d destinations, %d zero ranges; no relocation or function '
          'covers what the patch writes' % (label, len(build['code']), len(build['blobs']), len(build['zeros'])),
          flush=True)

    # --- the production guard and patch on the mapped copy ----------------------
    (folder / 'relocs.bin').write_bytes(struct.pack('<%dI' % len(relocs), *relocs))
    rel32 = lambda b, at: struct.unpack_from('<i', b, at)[0]
    for mode in ('preferred', 'view'):
        for split in (True, False):
            env = {} if split else {'MADEIRA_SC_IPC_SPLIT': '0'}
            before, after, log, view = run(binary, folder, img, mode, env)
            vtbase = IMAGE_BASE if mode == 'preferred' else view
            assert 'not patched' not in log and ('TimeDateStamp 0x%08x, vtable base 0x%x' % (pe.stamp, vtbase)) in log, log
            assert ('separate renderer IPC manager installed' if split else 'IPC split disabled') in log, log
            allowed = set()
            for rva, code, _, ipc in build['blobs']:
                if split or not ipc:
                    assert after[rva:rva + len(code)] == code, (label, hex(rva))
                    allowed.update(range(rva, rva + len(code)))
                else:
                    assert after[rva:rva + len(code)] == before[rva:rva + len(code)]
            for site, dest, span, opcode, ipc in build['hooks']:
                if split or not ipc:
                    assert after[site] == opcode and site + 5 + rel32(after, site + 1) == dest, (label, hex(site))
                    assert after[site + 5:site + span] == b'\x90' * (span - 5)
                    allowed.update(range(site, site + span))
                else:
                    assert after[site:site + span] == before[site:site + span]
            task = struct.unpack_from('<8Q', after, build['task'])
            assert task[0] == 0x30 and task[6] == 0 and task[7] == 1
            assert all(view <= p < view + pe.size for p in task[1:6]), 'callbacks use the view base'
            allowed.update(range(build['task'], build['task'] + 64))
            assert struct.unpack_from('<Q', after, build['vt_browser'] + 8 * R)[0] == vtbase + build['thunk']
            assert struct.unpack_from('<Q', after, build['vt_rph'])[0] == vtbase + build['loop_init']
            allowed.update(range(build['vt_browser'] + 8 * R, build['vt_browser'] + 8 * R + 8))
            allowed.update(range(build['vt_rph'], build['vt_rph'] + 8))
            diff = changed(before, after)
            stray = [hex(i) for i in diff if i not in allowed]
            assert not stray, (label, mode, stray[:8])
            print('PASS: %s: %s base, IPC split %s: logged success, %d bytes changed, all declared' %
                  (label, mode, 'on' if split else 'off', len(diff)), flush=True)

    # --- nothing written when off, on another image, or on any mismatch ---------
    for env in ({'MADEIRA_SC_RENDER_HANDLER': '0'}, {'MADEIRA_SC_CEF': '0'}):
        before, after, log, _ = run(binary, folder, img, 'preferred', env)
        assert before == after and '[sc-rph]' not in log, (env, log)
    before, after, log, _ = run(binary, folder, img, 'preferred', name='C:\\Windows\\notepad.exe')
    assert before == after and '[sc-rph]' not in log
    for rva, n, _ in build['code']:
        for at in (rva, rva + n - 1):
            tampered = bytearray(img)
            tampered[at] ^= 0x01
            before, after, log, _ = run(binary, folder, bytes(tampered), 'preferred')
            assert before == after and 'not patched: code bytes differ' in log, (label, hex(at), log)
    e = struct.unpack_from('<I', img, 0x3c)[0]
    others = [(e + 8, 'another build (TimeDateStamp / SizeOfImage)'),
              (build['vt_browser'] + 8 * R, 'CefApp vtables differ'),
              (build['vt_rph'] + 1, 'renderer OnWebKitInitialized differs')]
    s = build['prefix'][len('IOS_SCH'):-1]
    blob_why = re.findall(r'"([^"]+)" \}', table('ios_sch%s_blob' % s))
    zero_why = re.findall(r'"([^"]+)" \}', table('ios_sch%s_zero' % s))
    assert len(blob_why) == len(build['blobs']) and len(zero_why) == len(build['zeros'])
    guarded = lambda at: any(rva <= at < rva + n for rva, n, _ in build['code'])
    # A destination inside RET + int3 padding is a guarded window too: its
    # digest catches the change first.
    others += [(rva + len(code) - 1, 'code bytes differ' if guarded(rva + len(code) - 1) else what)
               for (rva, code, _, _), what in zip(build['blobs'], blob_why)]
    others += [(rva + n - 1, what) for (rva, n), what in zip(build['zeros'], zero_why)]
    for at, why in others:
        tampered = bytearray(img)
        tampered[at] ^= 0x01
        before, after, log, _ = run(binary, folder, bytes(tampered), 'preferred')
        assert before == after and 'not patched: ' + why in log, (label, hex(at), why, log)
    print('PASS: %s: switches off, another image name, %d one-byte window changes and %d header / vtable / '
          'destination changes write nothing; each mismatch logs its reason'
          % (label, 2 * len(build['code']), len(others)), flush=True)


builds = build_tables()
with tempfile.TemporaryDirectory(prefix='madeira-sc-helper-') as name:
    folder = Path(name)
    source = folder / 'patch.c'
    source.write_text(PRELUDE + function('static int ios_sc_path_is_helper(') + '\n' + region + '\n' + DRIVER)
    binary = folder / 'patch'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-O1',
                    '-fsanitize=address,undefined', '-g', str(source), '-o', str(binary)], check=True)
    for path in paths:
        check_binary(path, builds, binary, folder)
print('PASS: [sc-rph] every supplied helper build is guarded and patched exactly as declared')
