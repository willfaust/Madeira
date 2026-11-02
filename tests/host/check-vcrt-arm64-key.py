#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""env.MADEIRA_VCRT_ARM64_KEY, the volatile ARM64 Visual C++ redistributable marker
(build/ntdll-unix/server_ios.c, ios_vcrt_arm64_key_publish); no Wine runs.

An Unreal bootstrap exe is an x64 program on an ARM64 machine and stops with "Microsoft Visual C++
2015-2022 Redistributable (arm64)" (exit 0x2329). The prefix has the x64 and x86 markers only. The
switch writes the arm64 one for the session, volatile.

The compiled part needs Wine's headers: WINE_SRC points at a checkout (default ./wine); it is skipped
when they or a C compiler are missing.

1. Wiring, read from the files: loader_ios.c calls it in start_main_thread right after the hardware
   keys and before init_files; the one getenv; every key made by the volatile helper; the switch reads
   as off unless set (the function returns before touching the registry).
2. The function (server_ios.c from ios_vcrt_sz to its end, with ios_hw_key) compiled against a
   fake registry with Wine 11's parent rule: unset/empty/0 write nothing and log nothing; 1 writes
   14.44.35211.0 into both views, volatile; a version string writes that version; a bad value writes
   nothing and says so; a key already there is left alone; a repeated run adds nothing.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
n_dir = root / "build/ntdll-unix"
wine = Path(os.environ.get("WINE_SRC", root / "wine"))
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def func(src, sig):
    body = src[src.rindex(sig):]
    return body[:body.index("\n}\n") + 3]


loader = (n_dir / "loader_ios.c").read_text()
server = (n_dir / "server_ios.c").read_text()

# ------------------------------------------------------------ 1. wiring
smt = func(loader, "static void start_main_thread(void)")
i_hw, i_vc, i_files = smt.find("ios_hw_registry_publish();"), smt.find("ios_vcrt_arm64_key_publish();"), smt.find("init_files();")
check("start_main_thread: ios_hw_registry_publish -> ios_vcrt_arm64_key_publish -> init_files", 0 <= i_hw < i_vc < i_files)
check("engine: \"1\" writes 14.44.35211.0", "unsigned int v[4] = { 14, 44, 35211, 0 }" in server)
check("the call is iOS-only, declared next to it, and the only one",
      re.search(r"#ifdef WINE_IOS\n(?:\s*/\*.*?\*/\n)?\s*\{\n\s*extern void ios_vcrt_arm64_key_publish\(void\);\n"
                r"\s*ios_vcrt_arm64_key_publish\(\);\n\s*\}\n#endif", smt, re.S) is not None
      and loader.count("ios_vcrt_arm64_key_publish();") == 1 and server.count("ios_vcrt_arm64_key_publish();") == 0)
pub = func(server, "void ios_vcrt_arm64_key_publish(void)")
# the value writers, the version parser and the function: from ios_vcrt_sz to the function's end
region = server[server.index("static void ios_vcrt_sz( HANDLE key, const char *name, const char *value )"):
                server.index(pub) + len(pub)]
check("one getenv of MADEIRA_VCRT_ARM64_KEY, and the function returns on unset/empty/0 before any registry call",
      server.count('getenv( "MADEIRA_VCRT_ARM64_KEY" )') == 1
      and pub.index("return;") < pub.index("NtOpenKey") and pub.index("return;") < pub.index("ios_hw_key"))
check("keys are made by the volatile level-by-level helper only (no NtCreateKey of its own)",
      "ios_hw_key( machine, keys[i] )" in pub and "NtCreateKey" not in region)
check("an existing key is only opened for query, never written",
      "NtOpenKey( &key, KEY_QUERY_VALUE, &attr )" in pub and "KEY_SET_VALUE" not in pub)
check("the region sits inside the WINE_IOS block that ends before server_ios.c's server_init_process",
      server.rindex("#ifdef WINE_IOS", 0, server.index("void ios_vcrt_arm64_key_publish(void)"))
      < server.index("void ios_vcrt_arm64_key_publish(void)") < server.index("size_t server_init_process(void)"))

# ------------------------------------------------------------ 2. against a fake registry
harness = r'''
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif

static inline void ascii_to_unicode( WCHAR *dst, const char *src, size_t len )
{
    while (len--) *dst++ = (unsigned char)*src++;
}
static inline void init_unicode_string( UNICODE_STRING *str, const WCHAR *data )
{
    const WCHAR *p = data;
    while (*p) p++;
    str->Length = (p - data) * sizeof(WCHAR);
    str->MaximumLength = str->Length + sizeof(WCHAR);
    str->Buffer = (WCHAR *)data;
}

struct value { char name[32]; ULONG type; ULONG size; unsigned char data[100]; };
struct node { char name[96]; struct node *parent; int is_volatile; unsigned int nvalues; struct value values[12]; };
static struct node nodes[64];
static unsigned int node_count, creates, sets, log_lines, open_handles;
static char last_log[1024];
static struct node *root_node;

static void narrow( const UNICODE_STRING *s, char *out )
{
    unsigned int i, n = s->Length / sizeof(WCHAR);
    for (i = 0; i < n; i++) out[i] = (char)s->Buffer[i];
    out[n] = 0;
}
static struct node *child( struct node *parent, const char *name )
{
    unsigned int i;
    for (i = 0; i < node_count; i++)
        if (nodes[i].parent == parent && !strcasecmp( nodes[i].name, name )) return &nodes[i];
    return NULL;
}
static struct node *add( struct node *parent, const char *name, int vol )
{
    struct node *n = &nodes[node_count++];
    assert( node_count < ARRAY_SIZE(nodes) );
    memset( n, 0, sizeof(*n) );
    strcpy( n->name, name );
    n->parent = parent;
    n->is_volatile = vol;
    return n;
}
static struct node *walk( struct node *n, char *path, char **rest )
{
    char *p = path, *e;
    while (*p == '\\') p++;
    while (*p)
    {
        struct node *c;
        if ((e = strchr( p, '\\' ))) *e = 0;
        if (!(c = child( n, p ))) { if (e) *e = '\\'; *rest = p; return n; }
        n = c;
        if (!e) break;
        p = e + 1;
    }
    *rest = NULL;
    return n;
}
NTSTATUS WINAPI NtOpenKey( HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr )
{
    char path[512], *rest;
    struct node *n;
    narrow( attr->ObjectName, path );
    n = walk( attr->RootDirectory ? (struct node *)attr->RootDirectory : root_node, path, &rest );
    if (rest) return STATUS_OBJECT_NAME_NOT_FOUND;
    *key = n;
    open_handles++;
    return STATUS_SUCCESS;
}
/* Wine 11: NtCreateKey makes ONE key and fails when a parent is missing. */
NTSTATUS WINAPI NtCreateKey( HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG index,
                             const UNICODE_STRING *class, ULONG options, ULONG *dispos )
{
    char path[512], *rest;
    struct node *n;
    narrow( attr->ObjectName, path );
    n = walk( attr->RootDirectory ? (struct node *)attr->RootDirectory : root_node, path, &rest );
    if (rest)
    {
        if (strchr( rest, '\\' )) return STATUS_OBJECT_NAME_NOT_FOUND;
        if (n->is_volatile && !(options & REG_OPTION_VOLATILE)) return STATUS_CHILD_MUST_BE_VOLATILE;
        n = add( n, rest, !!(options & REG_OPTION_VOLATILE) );
        creates++;
    }
    *key = n;
    open_handles++;
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtSetValueKey( HANDLE key, const UNICODE_STRING *name, ULONG index, ULONG type,
                               const void *data, ULONG size )
{
    struct node *n = key;
    struct value *v = NULL;
    char vname[32];
    unsigned int i;
    narrow( name, vname );
    assert( size <= sizeof(v->data) );
    if (type == REG_SZ)
        assert( size % sizeof(WCHAR) == 0 && size >= sizeof(WCHAR) && !((const WCHAR *)data)[size / sizeof(WCHAR) - 1] );
    if (type == REG_DWORD) assert( size == sizeof(DWORD) );
    for (i = 0; i < n->nvalues; i++) if (!strcasecmp( n->values[i].name, vname )) v = &n->values[i];
    if (!v)
    {
        assert( n->nvalues < ARRAY_SIZE(n->values) );
        v = &n->values[n->nvalues++];
        strcpy( v->name, vname );
    }
    v->type = type;
    v->size = size;
    memcpy( v->data, data, size );
    sets++;
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtClose( HANDLE handle ) { assert( open_handles ); open_handles--; return STATUS_SUCCESS; }
static void wine_log_write( const char *fmt, ... ) __attribute__((format(printf, 1, 2)));
static void wine_log_write( const char *fmt, ... )
{
    va_list args;
    va_start( args, fmt );
    vsnprintf( last_log, sizeof(last_log), fmt, args );
    va_end( args );
    log_lines++;
}
''' + "@@HK@@\n" + "@@REGION@@" + r'''

static struct node *find( const char *path )
{
    char copy[512], *rest;
    struct node *n;
    strcpy( copy, path );
    n = walk( root_node, copy, &rest );
    return rest ? NULL : n;
}
static const char *vals( const char *path )
{
    static char out[1024];
    struct node *n = find( path );
    unsigned int i, k;
    out[0] = 0;
    if (!n) return "(missing)";
    for (i = 0; i < n->nvalues; i++)
    {
        struct value *v = &n->values[i];
        char *o = out + strlen( out );
        if (v->type == REG_DWORD) sprintf( o, "%s=dword:%u;", v->name, *(DWORD *)v->data );
        else
        {
            o += sprintf( o, "%s=sz:", v->name );
            for (k = 0; k + 1 < v->size / sizeof(WCHAR); k++) *o++ = (char)((WCHAR *)v->data)[k];
            *o++ = ';';
            *o = 0;
        }
    }
    return out;
}
/* The prefix template: Runtimes\x64 in both views and Wow6432Node's x86, no arm64. */
static void reset( void )
{
    struct node *m, *sw, *vc, *rt;
    node_count = creates = sets = log_lines = open_handles = 0;
    last_log[0] = 0;
    root_node = add( NULL, "", 0 );
    m = add( add( root_node, "Registry", 0 ), "Machine", 0 );
    sw = add( m, "Software", 0 );
    vc = add( add( add( add( sw, "Microsoft", 0 ), "VisualStudio", 0 ), "14.0", 0 ), "VC", 0 );
    rt = add( vc, "Runtimes", 0 );
    add( rt, "x64", 0 );
    vc = add( add( add( add( add( sw, "Wow6432Node", 0 ), "Microsoft", 0 ), "VisualStudio", 0 ), "14.0", 0 ), "VC", 0 );
    rt = add( vc, "Runtimes", 0 );
    add( rt, "x64", 0 );
    add( rt, "x86", 0 );
    unsetenv( "MADEIRA_VCRT_ARM64_KEY" );
}
#define K64  "\\Registry\\Machine\\Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\arm64"
#define K32  "\\Registry\\Machine\\Software\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\arm64"
#define DEF  "Bld=dword:35211;Installed=dword:1;Major=dword:14;Minor=dword:44;Rbld=dword:0;Version=sz:14.44.35211.0;"

int main( void )
{
    /* off: unset, empty, 0 -- not a registry call, not a log line */
    const char *off[] = { NULL, "", "0" };
    unsigned int i;
    for (i = 0; i < 3; i++)
    {
        reset();
        if (off[i]) setenv( "MADEIRA_VCRT_ARM64_KEY", off[i], 1 );
        ios_vcrt_arm64_key_publish();
        assert( !creates && !sets && !log_lines && !open_handles && !find( K64 ) && !find( K32 ) );
    }

    /* 1: 14.44.35211.0 in both views, volatile, one log line */
    reset();
    setenv( "MADEIRA_VCRT_ARM64_KEY", "1", 1 );
    ios_vcrt_arm64_key_publish();
    assert( !open_handles && creates == 2 && sets == 12 && log_lines == 1 );
    assert( find( K64 ) && find( K64 )->is_volatile && find( K32 ) && find( K32 )->is_volatile );
    assert( !strcmp( vals( K64 ), DEF ) && !strcmp( vals( K32 ), DEF ) );
    assert( !find( K64 )->parent->is_volatile && !find( K32 )->parent->is_volatile );   /* Runtimes stays as the prefix has it */
    assert( !strcmp( vals( "\\Registry\\Machine\\Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64" ), "" ) );
    assert( !strncmp( last_log, "[vcrt-arm64] ", 13 ) );
    assert( strstr( last_log, "HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\arm64 "
                              "(volatile) Installed=1 Version 14.44.35211.0: 2 of 2 view(s) written, 0 already there and "
                              "left alone, 0 could not be made; MADEIRA_VCRT_ARM64_KEY unset or 0 turns it off" ) );
    printf( "on: %u keys, %u values, line: %s\n", creates, sets, last_log );

    /* a second session in the same wineserver: the keys are there, left alone, no write */
    creates = sets = log_lines = 0;
    ios_vcrt_arm64_key_publish();
    assert( !creates && !sets && !open_handles && log_lines == 1 && !strcmp( vals( K64 ), DEF ) );
    assert( strstr( last_log, "0 of 2 view(s) written, 2 already there and left alone" ) );

    /* a version, three or four numbers */
    reset();
    setenv( "MADEIRA_VCRT_ARM64_KEY", "14.44.35211", 1 );
    ios_vcrt_arm64_key_publish();
    assert( !strcmp( vals( K64 ), "Bld=dword:35211;Installed=dword:1;Major=dword:14;Minor=dword:44;Rbld=dword:0;"
                                  "Version=sz:14.44.35211.0;" ) );
    reset();
    setenv( "MADEIRA_VCRT_ARM64_KEY", "14.50.36001.7", 1 );
    ios_vcrt_arm64_key_publish();
    assert( !strcmp( vals( K32 ), "Bld=dword:36001;Installed=dword:1;Major=dword:14;Minor=dword:50;Rbld=dword:7;"
                                  "Version=sz:14.50.36001.7;" ) );

    /* anything else writes nothing and says so */
    {
        const char *bad[] = { "yes", "2", "14.42", "14", "14.42.34433.0.1", "14.42.34433.", ".14.42.1", "14.42.x",
                              "14.42.34433 ", "1.2.123456", "-1.2.3", "14..3" };
        for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
        {
            reset();
            setenv( "MADEIRA_VCRT_ARM64_KEY", bad[i], 1 );
            ios_vcrt_arm64_key_publish();
            assert( !creates && !sets && !open_handles && log_lines == 1 && !find( K64 ) && !find( K32 ) );
            assert( strstr( last_log, "is neither 1 nor a version like 14.42.34433.0, nothing written" ) );
        }
    }

    /* a key the prefix already has (an installed redistributable) is never touched, the other view is made */
    reset();
    {
        struct node *rt = find( "\\Registry\\Machine\\Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes" );
        struct node *a = add( rt, "arm64", 0 );
        a->nvalues = 0;
    }
    setenv( "MADEIRA_VCRT_ARM64_KEY", "1", 1 );
    ios_vcrt_arm64_key_publish();
    assert( !strcmp( vals( K64 ), "" ) && !find( K64 )->is_volatile && !strcmp( vals( K32 ), DEF ) && find( K32 )->is_volatile );
    assert( creates == 1 && strstr( last_log, "1 of 2 view(s) written, 1 already there and left alone, 0 could not be made" ) );

    /* a prefix without Runtimes at all: the levels are made volatile too */
    reset();
    node_count = 0;
    root_node = add( NULL, "", 0 );
    add( add( add( root_node, "Registry", 0 ), "Machine", 0 ), "Software", 0 );
    setenv( "MADEIRA_VCRT_ARM64_KEY", "1", 1 );
    ios_vcrt_arm64_key_publish();
    assert( find( K64 ) && !strcmp( vals( K64 ), DEF ) && find( K64 )->parent->is_volatile );
    assert( find( K32 ) && !open_handles );

    /* a registry that refuses: counted, no crash, no half-written line */
    reset();
    node_count = 0;
    root_node = add( NULL, "", 0 );
    add( root_node, "Registry", 0 );                              /* no Machine key: every open fails */
    setenv( "MADEIRA_VCRT_ARM64_KEY", "1", 1 );
    ios_vcrt_arm64_key_publish();
    assert( !creates && !sets && !open_handles && strstr( last_log, "0 of 2 view(s) written, 0 already there and left alone, 2 could not be made" ) );

    puts( "harness ok" );
    return 0;
}
'''
harness = harness.replace("@@HK@@", func(server, "static HANDLE ios_hw_key( const char *base, const char *subpath )")) \
                 .replace("@@REGION@@", region)

if not CC:
    print("SKIP  the fake-registry run: no C compiler (set CC)")
elif not (wine / "include/windef.h").exists():
    print("SKIP  the fake-registry run: no Wine headers at %s (set WINE_SRC)" % (wine / "include"))
else:
  with tempfile.TemporaryDirectory(prefix="madeira-vcrt-") as tmpd:
    tmp = Path(tmpd)
    src = tmp / "harness.c"
    src.write_text(harness)
    exe = tmp / "harness"
    flags = ["-std=gnu11", "-O1", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-format-truncation",
             "-Wno-unused-but-set-variable", "-Wno-deprecated-declarations", "-Wno-pointer-sign", "-Wno-unknown-pragmas",
             # gcc only: strnlen's bound is the destination's size while the (NUL-terminated) source is smaller
             "-Wno-unknown-warning-option", "-Wno-stringop-overread",
             "-fshort-wchar", "-D__WINESRC__", "-DWINE_UNIX_LIB", "-I", str(wine / "include"), "-I", str(n_dir)]
    cc = subprocess.run([CC] + flags + [str(src), "-o", str(exe)], capture_output=True, text=True)
    if cc.returncode:
        print(cc.stderr[-4000:])
    check("the region compiles warning-free (-Werror) against Wine's headers (WINE_SRC, default ./wine)",
          cc.returncode == 0)
    if cc.returncode == 0:
        run = subprocess.run([str(exe)], capture_output=True, text=True)
        if run.returncode:
            print(run.stdout[-2000:], run.stderr[-2000:])
        check("fake-registry run: off writes nothing; 1 and versions write both views volatile; bad values and "
              "existing keys are left alone", run.returncode == 0 and "harness ok" in run.stdout)
        for line in run.stdout.splitlines():
            if line.startswith("on:"):
                print("     " + line)

print("PASS: env.MADEIRA_VCRT_ARM64_KEY" if ok else "FAILED: env.MADEIRA_VCRT_ARM64_KEY")
sys.exit(0 if ok else 1)
