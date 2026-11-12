#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""env.MADEIRA_UBI_CEF (on unless 0): Ubisoft Connect's browser upc.exe gets Chromium's process-count switches and keeps them.

Every 32-bit process needs its own guest window, so NtCreateUserProcess adds the switches to the browser's command line
(process_ios.c ubi_cef_cmdline). Ubisoft's libcef.dll discards that command line, so for a build listed in ios_ubi_cef_builds
virtual_ios.c ios_ubi_cef_patch turns the je that does it into nop; jmp, in the process's own view.

Checks (the production functions cut from the source into one harness, -Wall -Wextra -Werror, ASan + UBSan):
  1. ubi_cef_kind: upc.exe without --type= is the browser, upc.exe --type= and UplayWebCore.exe are helpers, others not CEF;
     ubi_cef_cmdline: a plain line gets exactly the five switches, a line that has some gets only the missing ones, its own
     --js-flags= gets no --jitless, jitless 0 adds none, a bare "--" gives -2, a too-small buffer -1;
  2. ios_ubi_cef_locate + ios_ubi_cef_apply on a synthetic PE32 DLL: the listed build (export name, stamp, size, the bytes at
     the site and at the jump target) is located and exactly 0f 84 -> 90 e9 changes; any one of those wrong, PE32+, x64 or
     not a DLL: nothing located or changed; truncated headers and views: nothing located, no read past the view;
     ios_ubi_cef_browser_process: upc.exe without --type= only; with UBI_LIBCEF_PATH=<a 32-bit libcef.dll> (only read) the
     listed build is accepted at RVA 0x287464 and two bytes change;
  3. wiring: the call right after ios_sc_render_handler_patch in map_image_into_view, before the section protections; the
     switch read with getenv at each call, off only for exactly "0", in both files; the [ubi-cef] tail goes through
     madeira_redact_line_w; the catalog (default 1), the session end; no MADEIRA_UBI_CEF_FLAGS in build/ntdll-unix.
Not covered: running the NtCreateUserProcess block and ios_ubi_cef_patch (neither file builds on a host; checked as text), a
real libcef.dll unless UBI_LIBCEF_PATH is set, and how FEX and Chromium then behave.
Needs a C compiler.
"""
from pathlib import Path
import os, re, shutil, struct, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
proc = (root / "build/ntdll-unix/process_ios.c").read_text()
virt = (root / "build/ntdll-unix/virtual_ios.c").read_text()
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[:1500]) if detail and not cond else ""))
    ok = ok and bool(cond)


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


# ---- the harness: the production code, driven by stdin lines (one output line each) --------------------------------
code = "".join(cut(proc, s, ";\n") for s in ("enum { UBI_NOT_CEF = 0", "enum { UBI_IN_PROCESS_GPU = 1"))
code += "".join(cut(proc, s) for s in ("static int ios_image_name_is(", "static int sc_switch_end(",
                                       "static int ubi_cef_kind(", "static int ubi_cef_cmdline("))
code += virt[virt.index("/* ubi-cef-test:begin */"):virt.index("/* ubi-cef-test:end */")]
MAIN = r"""
static WCHAR *wide( const char *s, size_t n )   /* exactly n WCHARs, no NUL: a read past them is reported */
{ WCHAR *w = malloc( (n ? n : 1) * sizeof(WCHAR) ); for (size_t i = 0; i < n; i++) w[i] = (unsigned char)s[i]; return w; }
static unsigned char *load( const char *path, size_t *n )   /* the whole file, in a buffer of exactly its size */
{
    FILE *f = fopen( path, "rb" );
    unsigned char *b = f && !fseek( f, 0, SEEK_END ) && (*n = (size_t)ftell( f )) && !fseek( f, 0, SEEK_SET ) ? malloc( *n ) : NULL;
    if (!b || fread( b, 1, *n, f ) != *n || fclose( f )) { perror( path ); exit( 2 ); }
    return b;
}
static unsigned char *map_pe( const unsigned char *f, size_t fn, size_t *n )   /* headers, then each section at its RVA */
{
    unsigned int pe = ios_ubi_le32( f + 0x3c ), opt = f[pe + 0x14] | (f[pe + 0x15] << 8), nsec = f[pe + 6] | (f[pe + 7] << 8), i;
    unsigned char *v = calloc( 1, *n = ios_ubi_le32( f + pe + 0x50 ) );
    memcpy( v, f, ios_ubi_le32( f + pe + 0x54 ) );
    for (i = 0; i < nsec; i++)
    {
        const unsigned char *s = f + pe + 0x18 + opt + 40 * i;
        size_t vs = ios_ubi_le32( s + 8 ), va = ios_ubi_le32( s + 12 ), raw = ios_ubi_le32( s + 16 ), off = ios_ubi_le32( s + 20 );
        size_t len = vs && vs < raw ? vs : raw;
        if (off + len <= fn && va + len <= *n) memcpy( v + va, f + off, len );
    }
    return v;
}
int main( void )
{
    char line[4096], *f[4];
    setvbuf( stdout, NULL, _IOLBF, 0 );   /* the lines before a sanitizer report stay */
    while (fgets( line, sizeof(line), stdin ))
    {
        char *p = line;
        int n = 0, how = 0, o, k;
        unsigned int site = 0;
        line[strcspn( line, "\n" )] = 0;
        while (n < 4 && p) { f[n++] = p; if ((p = strchr( p, '|' ))) *p++ = 0; }
        if (line[0] == 'K' || line[0] == 'B')   /* K|image|cmdline: ubi_cef_kind; B|image|cmdline: ios_ubi_cef_browser_process */
        {
            size_t il = strlen( f[1] ), cl = strlen( f[2] );
            WCHAR *im = wide( f[1], il ), *c = wide( f[2], cl );
            k = line[0] == 'B' ? ios_ubi_cef_browser_process( im, il, c, cl ) : ubi_cef_kind( im, (int)il, c, (int)cl );
            puts( line[0] == 'B' ? (k ? "yes" : "no")
                  : k == UBI_BROWSER ? "browser" : k == UBI_HELPER ? "helper" : k == UBI_NOT_CEF ? "not CEF" : "?" );
            free( im ); free( c );
        }
        else if (line[0] == 'C')   /* C|jitless|room|cmdline: ubi_cef_cmdline into exactly length + room WCHARs */
        {
            int cl = (int)strlen( f[3] ), cap = cl + atoi( f[2] );
            WCHAR *c = wide( f[3], cl ), *out = malloc( cap * sizeof(WCHAR) );
            o = ubi_cef_cmdline( c, cl, atoi( f[1] ), out, cap, &how );
            if (o < 0) printf( "%d", o );   /* else the new command line, its o characters and the NUL */
            for (k = 0; k < o; k++) putchar( (char)out[k] );
            puts( o >= 0 && out[o] ? " (no NUL)" : "" );
            free( c ); free( out );
        }
        else if (line[0] == 'T')   /* T|view|from|to: the view's first m bytes, m in [from, to), each in a buffer of m bytes */
        {
            size_t full, m, located = 0;
            unsigned char *v = load( f[1], &full ), *t;
            for (m = strtoul( f[2], NULL, 0 ); m < strtoul( f[3], NULL, 0 ) && m <= full; m++, free( t ))
                located += !ios_ubi_cef_locate( memcpy( t = malloc( m ? m : 1 ), v, m ), m, &site );
            printf( "%zu located\n", located );
            free( v );
        }
        else   /* V|view (RVA == offset) or P|PE file: locate, then apply as ios_ubi_cef_patch does; the changed bytes */
        {
            size_t fn, vn, changed = 0, i;
            unsigned char *file = load( f[1], &fn ), *v = line[0] == 'P' ? map_pe( file, fn, &vn ) : (vn = fn, file), *copy;
            const char *why;
            if (v != file) free( file );   /* a real file: only its mapped view is kept */
            copy = memcpy( malloc( vn ), v, vn );
            if ((why = ios_ubi_cef_locate( v, vn, &site ))) printf( "none (%s)", why );
            else printf( "0x%x %d", site, ios_ubi_cef_apply( v, site ) );
            for (i = 0; i < vn; i++) if (v[i] != copy[i] && ++changed <= 4) printf( " %zx:%02x>%02x", i, copy[i], v[i] );
            printf( " | %zu\n", changed );
            free( v ); free( copy );
        }
    }
    return 0;
}
"""

# ---- a synthetic PE32 DLL as the loader maps it (RVA == offset) -----------------------------------------------------
STAMP, SOI, RVA, REL = 0x67F4497D, 0x0BC62000, 0x287464, 0xB1   # the build ios_ubi_cef_builds lists; its je's rel32
TARGET = bytes.fromhex("8b5804 83780c00")                        # the two reads the jump target starts with
HIT = f"0x{RVA:x} 1 {RVA + 4:x}:0f>90 {RVA + 5:x}:84>e9 | 2"
NONE = re.compile(r"none \(.+\) \| 0")


def image(machine=0x14C, magic=0x10B, chars=0x2102, stamp=STAMP, soi=SOI, name=b"libcef.dll", rel=REL, target=TARGET):
    v = bytearray(0x288000)
    struct.pack_into("<2s58xI", v, 0, b"MZ", 0x80)                               # e_lfanew 0x80
    struct.pack_into("<4sHHIIIHH", v, 0x80, b"PE\0\0", machine, 1, stamp, 0, 0, 0xE0, chars)
    struct.pack_into("<H", v, 0x98, magic)
    struct.pack_into("<I", v, 0x80 + 0x50, soi)
    struct.pack_into("<II", v, 0x80 + 0x74, 16, 0x1000)                          # 16 data directories; exports at 0x1000
    struct.pack_into("<8sIIIIIIHHI", v, 0x178, b".text", 0x286000, 0x2000, 0x286000, 0x2000, 0, 0, 0, 0, 0x60000020)
    struct.pack_into("<I", v, 0x1000 + 0x0C, 0x1040)                             # the export directory's Name
    v[0x1040:0x1041 + len(name)] = name + b"\0"
    v[RVA:RVA + 10] = bytes.fromhex("83783800 0f84") + struct.pack("<I", rel)    # cmp dword [eax+0x38], 0; je rel32
    v[RVA + 10 + rel:RVA + 17 + rel] = target
    return bytes(v)


ALL = " --in-process-gpu --disable-site-isolation-trials --renderer-process-limit=1 --disable-component-update"
UPC = r'"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\upc.exe"'
BAD = {"a wrong TimeDateStamp": dict(stamp=STAMP + 1), "a wrong SizeOfImage": dict(soi=SOI + 0x1000),
       "other bytes at the site (rel32)": dict(rel=REL + 1), "another jump target": dict(target=b"\x8b\x58\x08" + TARGET[3:]),
       "PE32+": dict(magic=0x20B), "an x64 machine": dict(machine=0x8664), "not a DLL": dict(chars=0x0102),
       "export name chrome_elf.dll": dict(name=b"chrome_elf.dll"), "export name libcef.dll2": dict(name=b"libcef.dll2")}
CASES = [  # (what, input line, the output line or a pattern for it)
    ("ubi_cef_kind: upc.exe without --type= is the browser", rf"K|C:\Ubisoft\UPC.EXE|{UPC} -upc_desktop_mode", "browser"),
    ("ubi_cef_kind: upc.exe --type= is a helper", r"K|C:\x\upc.exe|upc.exe --type=renderer --lang=en-US", "helper"),
    ("ubi_cef_kind: UplayWebCore.exe is a helper", r"K|C:\x\UplayWebCore.exe|UplayWebCore.exe --type=gpu-process", "helper"),
    ("ubi_cef_kind: another image is not CEF", r"K|C:\x\UbisoftConnect.exe|UbisoftConnect.exe", "not CEF"),
    ("ubi_cef_cmdline: a plain upc.exe line gets exactly the five switches", f"C|1|200|{UPC} -upc_desktop_mode",
     f"{UPC} -upc_desktop_mode{ALL} --js-flags=--jitless"),
    ("ubi_cef_cmdline: a line that has some keeps them and gets only the missing ones",
     "C|1|200|upc.exe --renderer-process-limit=3 --in-process-gpu", "upc.exe --renderer-process-limit=3 --in-process-gpu"
     " --disable-site-isolation-trials --disable-component-update --js-flags=--jitless"),
    ("ubi_cef_cmdline: its own --js-flags= is kept, no --jitless", "C|1|200|upc.exe --js-flags=--max-old-space-size=64",
     f"upc.exe --js-flags=--max-old-space-size=64{ALL}"),
    ("ubi_cef_cmdline: jitless 0 adds no --jitless", "C|0|200|upc.exe -upc_desktop_mode", f"upc.exe -upc_desktop_mode{ALL}"),
    ('ubi_cef_cmdline: a bare "--" gives -2', "C|1|200|upc.exe -a -- file", "-2"),
    ("ubi_cef_cmdline: a too-small buffer gives -1", "C|1|100|upc.exe", "-1"),
    ("ios_ubi_cef_browser_process: upc.exe without --type=", rf"B|C:\Ubisoft\upc.exe|{UPC} -upc_desktop_mode", "yes"),
    ("ios_ubi_cef_browser_process: upc.exe --type=", r"B|C:\x\upc.exe|upc.exe --type=renderer", "no"),
    ("ios_ubi_cef_browser_process: another image", r"B|C:\x\UplayWebCore.exe|UplayWebCore.exe", "no"),
    ("the listed build is located at its RVA and exactly 0f 84 -> 90 e9 changes", "V|{tmp}/good.dll", HIT),
    *((f"{what}: nothing located, nothing changed", f"V|{{tmp}}/bad{i}.dll", NONE) for i, what in enumerate(BAD)),
    ("truncated headers: nothing located, no read past the view", "T|{tmp}/good.dll|0|0x1100", "0 located"),
    ("a view that ends before the site or its target: nothing located", f"T|{{tmp}}/good.dll|{RVA}|{RVA + 17 + REL}", "0 located")]
if os.environ.get("UBI_LIBCEF_PATH"):   # mapped in the harness; the file is only read
    CASES.append((f"the real libcef.dll is accepted at RVA 0x{RVA:x}, exactly two bytes change",
                  "P|" + os.environ["UBI_LIBCEF_PATH"], HIT))
else:
    print("SKIP: a real libcef.dll (set UBI_LIBCEF_PATH to a 32-bit libcef.dll; it is only read)")

if not cc:
    check("a C compiler for the host test", False)
else:
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "good.dll").write_bytes(image())
        for i, kw in enumerate(BAD.values()):
            (Path(tmp) / f"bad{i}.dll").write_bytes(image(**kw))
        c, exe = Path(tmp) / "ubi.c", Path(tmp) / "ubi"
        c.write_text("#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\ntypedef unsigned short WCHAR;\n" + code + MAIN)
        r = subprocess.run([cc, "-std=gnu11", "-g", "-O1", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                            "-fno-sanitize-recover=all", "-o", str(exe), str(c)], capture_output=True, text=True)
        check("the harness compiles (-Wall -Wextra -Werror, ASan + UBSan)", r.returncode == 0, r.stderr)
        if r.returncode == 0:
            r = subprocess.run([str(exe)], input="".join(i.replace("{tmp}", tmp) + "\n" for _, i, _ in CASES),
                               capture_output=True, text=True, env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"))
            check("the harness runs without a sanitizer report", r.returncode == 0, f"exit status {r.returncode}\n{r.stderr}")
            for (what, _, want), got in zip(CASES, r.stdout.splitlines() + [None] * len(CASES)):
                check(what, got is not None and (want.fullmatch(got) if isinstance(want, re.Pattern) else got == want), got)

# ---- wiring -----------------------------------------------------------------------------------------------------------
mapper = cut(virt, "static NTSTATUS map_image_into_view(")
call = re.search(r"\n\s*ios_sc_render_handler_patch\( ptr, total_size, nt, sec, nt_name \);\n(?:\s*/\*.*\*/\n)*"
                 r"\s*ios_ubi_cef_patch\( ptr, total_size, nt, nt_name \);\n", mapper)
check("ios_ubi_cef_patch is called once, right after ios_sc_render_handler_patch, before the section protections",
      call is not None and mapper.count("ios_ubi_cef_patch(") == 1
      and call.end() < mapper.index("set_vprot( view, ptr + sec[i].VirtualAddress") < mapper.index("mprotect_exec("))
create = cut(proc, "NTSTATUS WINAPI NtCreateUserProcess(")
block = create[create.rindex("{", 0, create.index('getenv( "MADEIRA_UBI_CEF" )')):]
block = block[:block.index("\n    }\n")]
for what, body in (("virtual_ios.c ios_ubi_cef_patch", cut(virt, "static void ios_ubi_cef_patch(")),
                   ("process_ios.c NtCreateUserProcess", block)):
    var = re.search(r'const char \*(\w+) = getenv\( "MADEIRA_UBI_CEF" \);', body)
    check(f'{what}: the switch is read with getenv at each call, off only for exactly "0"',
          var is not None and body.count('getenv( "MADEIRA_UBI_CEF" )') == 1
          and not re.search(r"\bstatic\b", body.split("\n", 1)[1])
          and re.search(r"\(\s*{0} && {0}\[0\] == '0' && !{0}\[1\]\s*\)".format(var.group(1)), body) is not None)
check("the process block rewrites only the browser's line, refuses nothing, logs the tail of the redacted line",
      "kind == UBI_BROWSER" in block and "ubi_cef_cmdline( params->CommandLine.Buffer, cl_len," in block
      and "sn = madeira_redact_line_w( (const unsigned short *)nbuf, (size_t)o, shown, tcap );" in block
      and block.index("madeira_redact_line_w(") < block.index('"[ubi-cef] cmdline-tail: ...%s\\n", tail )')
      and "return" not in block)
gen, cat = ((root / f).read_text() for f in ("build/tools/gen-config-catalog.py", "app/Madeira/ConfigCatalog.generated.swift"))
check("the catalog documents env.MADEIRA_UBI_CEF, default 1; the session end clears it",
      re.search(r'"env\.MADEIRA_UBI_CEF": \{[^}]*"default": "1"', gen) is not None
      and re.search(r'key: "env\.MADEIRA_UBI_CEF",[^\n]*defaultValue: "1"', cat) is not None
      and 'unsetenv("MADEIRA_UBI_CEF");' in (root / "app/Madeira/WineProcessBridge.m").read_text())
stale = [p.name for p in sorted((root / "build/ntdll-unix").iterdir()) if p.is_file()
         and "MADEIRA_UBI_CEF_FLAGS" in p.read_text(errors="replace")]
check("no MADEIRA_UBI_CEF_FLAGS in build/ntdll-unix", not stale, stale)
print("PASS: ubi-cef" if ok else "FAILED: ubi-cef")
sys.exit(0 if ok else 1)
