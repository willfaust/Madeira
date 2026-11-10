#!/usr/bin/env python3
"""Social Club's Chromium: one CEF process, its libcef.dll copy and its glued pools; no Wine runs.

GTA V Enhanced (logs 2026-10-02 16:19 / 16:33): the game loaded libcef.dll itself and its
240 MB pool copy was refused (pool EXHAUSTED); each SocialClubHelper.exe then reserved
PartitionAlloc's glued 32 GB pools, got 0x7400000000 (not 32 GB aligned) three times,
asked for 64 GB - 64 KB to align it itself and died at chrome_elf.dll+0x13add4. Five
helpers were started.

Compiles the production code and checks:
  - process_ios.c (sc_switch_end, sc_helper_kind, sc_browser_cmdline): only
    SocialClubHelper.exe matches; a --type= child is a child; the browser gets
    --single-process, --js-flags=--jitless (unless MADEIRA_JITLESS=0 or its own
    --js-flags=), PartitionAllocBackupRefPtr first in its LAST --disable-features= list
    (a new switch only when it has none) and MADEIRA_SC_CEF_FLAGS; a too small buffer
    fails; look-alike switches are not taken for the real ones; a --js-flags= inside
    MADEIRA_SC_CEF_FLAGS (sc_extra_js_flags) gets --jitless as its first flag instead
    of a second switch, and Windows' argument splitting (a port of
    CommandLineToArgvW) then reads the last --js-flags= as "--jitless ..." whether the
    value was quoted, bare, empty or repeated;
  - virtual_ios.c (ios_sc_name_is, ios_sc_path_is_helper, ios_sc_refused_name, ios_sc_cef_refuse):
    libcef.dll and nvngx_dlss(g).dll are refused only in a Social Club client that is not the
    helper, with the switch on (log 21:26: nvngx_dlss.dll's 28 MB left libcef 1.8 MB short);
  - virtual_ios.c ios_sc2_reported_highest: in layout 2, SocialClubHelper.exe alone (64-bit,
    limit not already wider) is told HighestUserAddress 2 TB - 1; a model of V8 14's
    DetermineAddressSpaceLimit (FEX's CPUID: 48 bits) then passes its CHECK (1 TB sandbox <
    limit), which the clamped 512 GB fails, and plans a partially reserved sandbox of
    512 GB halving to 8 GB; placement and server_ios.c's remote-allocation limits keep the
    real limit (ios_highest_user_address);
  - virtual_ios.c env.MADEIRA_SC_PA_POOLS (ios_sc_pa_hold_arena, ios_sc_glued_pools,
    ios_sc_pa_drop_hold) against a model Mach map and allocator: not opted in, nothing
    moves and nothing is granted; opted in, the FEX arena boots at 0x7d00000000 (12 GB)
    with [0x7c00000000, +4 GB) held, the helper's ask gets 32 GB at 0x7800000000 with
    [0x7800000000, 0x7d00000000) really reserved, a blocked range puts the hold back, a
    restarted helper gets the range again;
and the call sites textually (NtCreateUserProcess gate, mprotect_exec refusal,
map_image_into_view's STATUS_NO_MEMORY, the hinted jumbo branch, the FEX arena).
Needs python3 and a C compiler (AddressSanitizer/UBSan).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
proc = (root / 'build/ntdll-unix/process_ios.c').read_text()
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


# --- call sites ---------------------------------------------------------------
create = function(proc, 'NTSTATUS WINAPI NtCreateUserProcess(')
gate = create[create.index('/* madeira-bcd: Social Club\'s Chromium -- see sc_helper_kind. */'):]
gate = gate[:gate.index('unixdir = get_unix_curdir( params );')]
assert 'getenv( "MADEIRA_SC_CEF" )' in gate and "(sc && sc[0] == '0') ? SC_NOT_HELPER" in gate
assert 'if (kind == SC_CHILD)' in gate and 'return STATUS_ACCESS_DENIED;' in gate
assert 'getenv( "MADEIRA_JITLESS" )' in gate and 'getenv( "MADEIRA_SC_CEF_FLAGS" )' in gate
assert 'params->CommandLine.Buffer = nbuf;' in gate
assert create.index('task #34 single-process CEF') < create.index("Social Club's Chromium -- see sc_helper_kind") \
    < create.index('create_startup_info( attr.ObjectName')
print('PASS: NtCreateUserProcess refuses a helper --type= child and rewrites the browser before the startup info')
assert 'ec_conhost_refuse( is_arm64ec(), getenv( "MADEIRA_EC_CONHOST" ), params->ImagePathName.Buffer,' in create
conhost = create[create.index('if (ec_conhost_refuse('):][:900]
assert 'return STATUS_ACCESS_DENIED;' in conhost
assert create.index('if (ec_conhost_refuse(') < create.index('create_startup_info( attr.ObjectName')
print('PASS: NtCreateUserProcess refuses conhost.exe in an ARM64EC session before the startup info')
assert 'child_extra_args( getenv( "MADEIRA_CHILD_ARGS" ), params->ImagePathName.Buffer,' in create
assert create.index('if (ec_conhost_refuse(') < create.index('child_extra_args( getenv') < create.index('create_startup_info( attr.ObjectName')

mprot = function(native, 'static inline int mprotect_exec( void *base, size_t size, int unix_prot )')
refuse = mprot[mprot.index("/* madeira-bcd: a Social Club client's libcef.dll and DLSS runtimes"):]
refuse = refuse[:refuse.index('/* ml457 REVERTED (ml458)')]
assert 'ios_sc_cef_refuse( sc_mod, 1, ios_sc_current_is_helper(), ios_sc_current_has_socialclub(),\n                                   ios_sc_game_cef() )' in refuse
assert 'ios_sc_cef_enabled() && ios_sc_refused_name( sc_mod ) &&' in refuse
assert 'ios_jit_copy_refused = 2;' in refuse and 'return -1;' in refuse
exhausted = mprot[mprot.index('[jit-pool] EXHAUSTED (image %p+0x%lx)'):][:900]
assert 'ios_jit_copy_refused = 1;' in exhausted
mapimg = function(native, 'static NTSTATUS map_image_into_view(')
loop = mapimg[mapimg.index('ios_jit_copy_refused = 0;'):mapimg.index('VALGRIND_LOAD_PDB_DEBUGINFO')]
assert 'if (ios_jit_copy_refused)' in loop and 'status = STATUS_NO_MEMORY;' in loop and 'goto done;' in loop
res = loop.index('if (ios_resource_only_map( ios_jit_copy_refused, NtCurrentTeb()->Tib.ArbitraryUserPointer ))')
assert res < loop.index('if (ios_jit_copy_refused)\n')
assert 'ios_noexec_resource = 1;' in loop[res:res + 900] and 'continue;' in loop[res:res + 900]
assert 'si < nt->FileHeader.NumberOfSections && !ios_noexec_resource; si++' in mapimg
assert loop.index('for (i = 0; i < nt->FileHeader.NumberOfSections; i++)') > 0
print('PASS: a refused pool copy (exhausted, or a client\'s libcef.dll) fails the image load with STATUS_NO_MEMORY; '
      'a resource-only map of a policy-refused image maps without exec and skips the eager JIT copy')

hinted = native[native.index('/* task#29 CEF plan C: a HINTED jumbo reserve that fails placement'):][:6000]
glue = hinted[hinted.index('ios_sc_glued_pools( &pick, &sz, type, protect )') - 200:]
assert '*size_ptr == 0x800000000ULL && !((ULONG_PTR)hint & (0x800000000ULL - 1))' in glue
assert '!sc2 && sc_helper && *size_ptr == 0x800000000ULL' in glue, 'layout 2 routes instead (check-sc-layout)'
assert 'int sc_helper = ios_sc_cef_enabled() && ios_sc_current_is_cef_host();' in hinted
assert 'if (st2 && off)' in hinted and 'else if (st2) for (slot = 0x7C00000000ULL;' in hinted
arena = function(native, 'void ios_reserve_fex_arena(void)')
assert 'if (i == 0 && ios_sc_pa_hold_arena( &addr, &size )) goto sc_arena_placed;' in arena
assert arena.index('goto sc_arena_placed;') < arena.index('    sc_arena_placed:\n        base = (void *)(ULONG_PTR)addr;')
assert 'if (ios_sc_brp_layout) { ios_sc_pa_drop_hold(); i--; }' in arena
assert 'ios_soft' not in function(native, 'static NTSTATUS ios_sc_glued_pools('), 'no soft entry over FEX\'s arena'
print('PASS: only SocialClubHelper.exe\'s 32 GB-aligned 32 GB reserve takes the glued-pools path; '
      'the FEX arena moves only with env.MADEIRA_SC_PA_POOLS = 1')

sysinfo = function(native, 'void virtual_get_system_info( SYSTEM_BASIC_INFORMATION *info, BOOL wow64 )')
real_expr = ('    if (wow64) info->HighestUserAddress = (char *)get_wow_user_space_limit() - 1;\n'
             '    else info->HighestUserAddress = (char *)user_space_limit - 1;\n')
widen = sysinfo.index('ios_sc2_reported_highest( real, wow64, ios_sc_layout_mode, ios_sc_current_is_cef_host() );')
assert sysinfo.index(real_expr) < widen < sysinfo.index('/* ml991: report, once,'), 'widened after the real value, logged by ml991'
assert 'if (!wow64 && ios_sc_layout_mode == 2 && ios_sc_cef_enabled())' in sysinfo
assert 'user_space_limit =' not in sysinfo, 'only the report changes'
real_fn = function(native, 'ULONG_PTR ios_highest_user_address( BOOL wow64 )')
assert 'return wow64 ? get_wow_user_space_limit() - 1 : (ULONG_PTR)user_space_limit - 1;' in real_fn
server = (root / 'build/ntdll-unix/server_ios.c').read_text()
assert 'sbi.HighestUserAddress' not in server and 'virtual_get_system_info' not in server, \
    'remote-allocation limits must not use the reported (possibly widened) value'
assert server.count('limit_high = min( ios_highest_user_address( is_wow64() ), call->') == 2
print('PASS: virtual_get_system_info widens only the report; server_ios.c\'s remote-allocation limits use the real one')

# --- the code under test ----------------------------------------------------------
enums = proc[proc.index('enum { SC_NOT_HELPER = 0'):]
enums = enums[:enums.index('\n\n')] + '\n'
proc_helpers = enums + ''.join(function(proc, sig) for sig in (
    'static int sc_switch_end(',
    'static int ios_image_name_is(',   # renamed in the merge (same body)
    'static int ec_conhost_refuse(',
    'static const char *child_extra_args(',
    'static int sc_helper_kind(',
    'static int sc_extra_js_flags(',
    'static int sc_browser_cmdline(',
))
virt_helpers = ''.join(function(native, sig) for sig in (
    'static int ios_sc_name_is(',
    'static int ios_sc_path_is_helper(',
    'static int ios_sc_refused_name(',
    'static int ios_sc_cef_refuse(',
    'static int ios_resource_only_map(',
))
sc_decl = native[native.index('#define IOS_SC_GLUED_BASE'):]
sc_decl = sc_decl[:sc_decl.index('static int ios_sc_brp_layout;')] + 'static int ios_sc_brp_layout;\n'
sc_decl += ''.join(m.group(0) + '\n' for m in re.finditer(r'^#define IOS_SC2_\w+\s+\S+', native, re.M))
sc_decl += 'enum { IOS_SC_K_V1 = 8 };\nstatic int ios_sc_layout_mode = -1, grants;\n'
# madeira-bcd: the arena starts here (IOS_SC2_RDR2_ARENA_BASE with env MADEIRA_RDR2_VA_HOLD; not modelled)
sc_decl += 'static uint64_t ios_sc2_arena_lo = IOS_SC_ARENA_BASE;\n'
sc_decl += 'static void *ios_jit_current_peb( void ) { return (void *)1; }\n'
sc_decl += 'static void ios_va_release_note( void ) {}\n'
sc_decl += 'static const char *ios_sc_host_name( char *b, size_t n ) { snprintf( b, n, "SocialClubHelper.exe" ); return b; }\n'   # the placement proof's epoch (check-place-proof.py)
sc_decl += ('static void ios_sc_grant_add( uint64_t v, uint64_t r, uint64_t real, uint64_t asked, int k, void *p ) '
            '{ (void)v; (void)r; (void)real; (void)asked; (void)k; (void)p; grants++; }\n')
# madeira-bcd pool-low: ios_sc_layout reads the alias reservation's base from region C
sc_decl += '#define IOS_POOL_LOW_MIN (16u * 1024 * 1024)\n'
sc_decl += function(native, 'static int ios_pool_low_parse(') + function(native, 'static void ios_pool_alias_extent(')
sc_decl += function(native, 'static int ios_sc_layout_pick(') + function(native, 'static int ios_sc_layout(void)')
glued = function(native, 'static ULONG_PTR ios_sc2_reported_highest(') + \
    function(native, 'static int ios_sc_pa_hold_arena(') + \
    function(native, 'static void ios_sc_pa_drop_hold(void)') + \
    function(native, 'static NTSTATUS ios_sc_glued_pools(')

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
typedef uint16_t WCHAR;
typedef unsigned int NTSTATUS, ULONG;
typedef size_t SIZE_T;
typedef uintptr_t ULONG_PTR;
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY 0xc0000017
#define STATUS_CONFLICTING_ADDRESSES 0xc0000018
#define dprintf(fd, ...) fprintf( stderr, __VA_ARGS__ )
#define FAIL(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)
''' + proc_helpers + virt_helpers + r'''
/* --- a model of the Mach map: a list of ranges --- */
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef int kern_return_t;
#define KERN_SUCCESS 0
#define KERN_NO_SPACE 3
#define VM_FLAGS_FIXED 0
#define MEMORY_OBJECT_NULL 0
#define PROT_NONE 0
#define VM_PROT_ALL 7
#define VM_INHERIT_COPY 1
#define MEM_RELEASE 0x8000
static struct { uint64_t base, size; } vm[16];
static int nvm, fail_map_n;
static int mach_task_self( void ) { return 1; }
static int vm_overlaps( uint64_t b, uint64_t s )
{
    int i;
    for (i = 0; i < nvm; i++) if (b < vm[i].base + vm[i].size && b + s > vm[i].base) return 1;
    return 0;
}
static void vm_add( uint64_t b, uint64_t s ) { vm[nvm].base = b; vm[nvm].size = s; nvm++; }
static void vm_del( uint64_t b )
{
    int i;
    for (i = 0; i < nvm; i++) if (vm[i].base == b) { vm[i] = vm[--nvm]; return; }
    FAIL("no range at 0x%llx\n", (unsigned long long)b);
}
static kern_return_t mach_vm_map( int t, mach_vm_address_t *a, mach_vm_size_t s, uint64_t mask, int flags, int obj,
                                  uint64_t off, int copy, int cur, int max, int inh )
{
    (void)t; (void)mask; (void)flags; (void)obj; (void)off; (void)copy; (void)cur; (void)max; (void)inh;
    if (fail_map_n && !--fail_map_n) return KERN_NO_SPACE;
    if (vm_overlaps( *a, s )) return KERN_NO_SPACE;
    vm_add( *a, s );
    return KERN_SUCCESS;
}
static kern_return_t mach_vm_deallocate( int t, mach_vm_address_t a, mach_vm_size_t s )
{
    int i;
    (void)t;
    for (i = 0; i < nvm; i++)
        if (vm[i].base == a && vm[i].size == s) { vm[i] = vm[--nvm]; return KERN_SUCCESS; }
    FAIL("deallocate of an unknown range 0x%llx+0x%llx\n", (unsigned long long)a, (unsigned long long)s);
    return 1;
}
static int calls;
static NTSTATUS allocate_virtual_memory( void **ret, SIZE_T *size, ULONG type, ULONG protect,
                                         unsigned long a, unsigned long b, int c, int d )
{
    (void)type; (void)protect; (void)a; (void)b; (void)c; (void)d;
    calls++;
    if ((uintptr_t)*ret != 0x7800000000ull || *size != 0x500000000ull)
        FAIL("asked for 0x%llx+0x%llx\n", (unsigned long long)(uintptr_t)*ret, (unsigned long long)*size);
    if (vm_overlaps( 0x7800000000ull, *size )) return STATUS_CONFLICTING_ADDRESSES;
    vm_add( 0x7800000000ull, *size );
    return STATUS_SUCCESS;
}
static void *NtCurrentProcess( void ) { return (void *)~(uintptr_t)0; }
static NTSTATUS NtFreeVirtualMemory( void *p, void **a, SIZE_T *s, ULONG t ) { (void)p; (void)a; (void)s; (void)t; return 0; }
''' + sc_decl + glued + r'''
static WCHAR *w( const char *s, int *len )
{
    static WCHAR buf[8][2048];
    static int k;
    WCHAR *o = buf[k++ & 7];
    int n = 0;
    for (; s[n]; n++) o[n] = (unsigned char)s[n];
    o[n] = 0;
    *len = n;
    return o;
}

static const char *a( const WCHAR *s, int len )
{
    static char buf[4096];
    int i;
    for (i = 0; i < len; i++) buf[i] = (char)s[i];
    buf[len] = 0;
    return buf;
}

static const char *helper = "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe";

static int kind( const char *image, const char *cl )
{
    int il, cll;
    WCHAR *wi = w( image, &il ), *wc = w( cl, &cll );
    return sc_helper_kind( wi, il, wc, cll );
}

static const char *rewrite( const char *cl, int jitless, const char *extra, int *how )
{
    static WCHAR out[4096];
    int cll, n;
    WCHAR *wc = w( cl, &cll );
    n = sc_browser_cmdline( wc, cll, jitless, extra, out, 4096, how );
    if (n < 0) FAIL("rewrite failed for %s\n", cl);
    if (out[n]) FAIL("not NUL-terminated\n");
    return a( out, n );
}

static void expect( const char *got, const char *want )
{
    if (strcmp( got, want )) FAIL("got  [%s]\nwant [%s]\n", got, want);
}

/* The last argument starting with --js-flags= as Windows splits the command line
 * (Chromium's CommandLine::ParseFromString calls CommandLineToArgvW; this is
 * Wine's shell32 algorithm for the arguments after the first), or "" */
static const char *last_js_flags( const char *s )
{
    static char arg[4096], last[4096];
    char *d;
    int bcount, qcount;

    last[0] = 0;
    if (*s == '"') { s++; while (*s && *s != '"') s++; if (*s) s++; }   /* the program name */
    else while (*s && *s != ' ' && *s != '\t') s++;
    while (*s == ' ' || *s == '\t') s++;
    while (*s)
    {
        d = arg; bcount = qcount = 0;
        while (*s && !((*s == ' ' || *s == '\t') && !qcount))
        {
            if (*s == '\\') { *d++ = *s++; bcount++; }
            else if (*s == '"')
            {
                if (!(bcount & 1)) { d -= bcount / 2; qcount++; }
                else { d = d - bcount / 2 - 1; *d++ = '"'; }
                s++; bcount = 0;
                while (*s == '"') { if (++qcount == 3) { *d++ = '"'; qcount = 0; } s++; }
                if (qcount == 2) qcount = 0;
            }
            else { *d++ = *s++; bcount = 0; }
        }
        *d = 0;
        if (!strncmp( arg, "--js-flags=", 11 )) strcpy( last, arg );
        while (*s == ' ' || *s == '\t') s++;
    }
    return last;
}

static void gate_and_cmdline( void )
{
    const char *cl = "\"C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe\"  "
                     "--allow-file-access-from-files --lang=en --off-screen-rendering-enabled";
    int how;

    if (kind( helper, cl ) != SC_BROWSER) FAIL("browser not recognised\n");
    if (kind( "\\??\\c:\\program files\\rockstar games\\social club\\socialclubhelper.exe", cl ) != SC_BROWSER)
        FAIL("NT path, lower case\n");
    if (kind( helper, "x.exe --type=renderer --lang=en" ) != SC_CHILD) FAIL("renderer child\n");
    if (kind( helper, "x.exe \"--type=gpu-process\"" ) != SC_CHILD) FAIL("quoted child\n");
    if (kind( helper, "x.exe --no-type=renderer" ) != SC_BROWSER) FAIL("--no-type= taken for --type=\n");
    if (kind( "C:\\x\\NotSocialClubHelper.exe", cl ) != SC_NOT_HELPER) FAIL("look-alike image\n");
    if (kind( "C:\\x\\SocialClubHelper.exe.bak", cl ) != SC_NOT_HELPER) FAIL("suffix\n");
    if (kind( "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe", "a --type=renderer" ) != SC_NOT_HELPER)
        FAIL("steamwebhelper\n");
    printf("PASS: only SocialClubHelper.exe is matched; --type= makes it a child\n");
    {
        int l1, l2, l3, l4;
        WCHAR *ch = w( "C:\\windows\\system32\\conhost.exe", &l1 ), *ch2 = w( "\\??\\C:\\Windows\\System32\\CONHOST.EXE", &l2 );
        WCHAR *nc = w( "C:\\x\\notconhost.exe", &l3 ), *nc2 = w( "C:\\x\\conhost.exe.bak", &l4 );
        if (!ec_conhost_refuse( 1, NULL, ch, l1 ) || !ec_conhost_refuse( 1, "0", ch2, l2 )) FAIL("EC conhost allowed\n");
        if (ec_conhost_refuse( 0, NULL, ch, l1 )) FAIL("aarch64 session conhost refused\n");
        if (ec_conhost_refuse( 1, "1", ch, l1 )) FAIL("MADEIRA_EC_CONHOST=1 refused\n");
        if (ec_conhost_refuse( 1, NULL, nc, l3 ) || ec_conhost_refuse( 1, NULL, nc2, l4 ) ||
            ec_conhost_refuse( 1, NULL, NULL, 0 )) FAIL("look-alike conhost refused\n");
    }
    printf("PASS: conhost.exe is refused only in an ARM64EC session, unless MADEIRA_EC_CONHOST=1\n");
    {
        int l1, l2;
        WCHAR *g = w( "C:\\Grand Theft Auto V Enhanced\\GTA5_Enhanced.exe", &l1 ), *pg = w( "C:\\x\\PlayGTAV.exe", &l2 );
        const char *e = child_extra_args( "GTA5_Enhanced.exe -scDebugLogging -x", g, l1 );
        if (!e || strcmp( e, "-scDebugLogging -x" )) FAIL("child args\n");
        e = child_extra_args( "  gta5_enhanced.EXE   -a", g, l1 );
        if (!e || strcmp( e, "-a" )) FAIL("child args case/spaces\n");
        if (child_extra_args( "GTA5_Enhanced.exe -a", pg, l2 ) || child_extra_args( "GTA5_Enhanced.exe", g, l1 ) ||
            child_extra_args( NULL, g, l1 ) || child_extra_args( "", g, l1 ) ||
            child_extra_args( "GTA5_Enhanced.ex -a", g, l1 )) FAIL("child args mismatch\n");
    }
    printf("PASS: env.MADEIRA_CHILD_ARGS appends only to the named image, only when it has arguments\n");

    expect( rewrite( cl, 1, NULL, &how ),
            "\"C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe\"  --allow-file-access-from-files "
            "--lang=en --off-screen-rendering-enabled --disable-features=PartitionAllocBackupRefPtr --single-process "
            "--js-flags=--jitless --no-proxy-server" );
    if (how != (SC_BRP_NEW | SC_SINGLE_ADDED | SC_JITLESS_ADDED | SC_NOPROXY_ADDED)) FAIL("how=%x\n", how);
    expect( rewrite( "h.exe --disable-features=A,B --x", 1, NULL, &how ),
            "h.exe --disable-features=PartitionAllocBackupRefPtr,A,B --x --single-process --js-flags=--jitless --no-proxy-server" );
    if (!(how & SC_BRP_SPLICED) || (how & SC_BRP_NEW)) FAIL("splice how=%x\n", how);
    expect( rewrite( "h.exe --disable-features=A --disable-features=\"B,C\"", 0, NULL, &how ),
            "h.exe --disable-features=A --disable-features=PartitionAllocBackupRefPtr,\"B,C\" --single-process --no-proxy-server" );
    expect( rewrite( "h.exe --single-process --js-flags=--max-old-space-size=64 --proxy-server=x:1", 1, "--disable-gpu --v=1", &how ),
            "h.exe --single-process --js-flags=--max-old-space-size=64 --proxy-server=x:1 "
            "--disable-features=PartitionAllocBackupRefPtr --disable-gpu --v=1" );
    if (how != (SC_BRP_NEW | SC_OWN_JS_FLAGS | SC_EXTRA_ADDED)) FAIL("how=%x\n", how);
    expect( rewrite( "h.exe --single-process-x --foo=--disable-features=Z", 1, "", &how ),
            "h.exe --single-process-x --foo=--disable-features=Z --disable-features=PartitionAllocBackupRefPtr "
            "--single-process --js-flags=--jitless --no-proxy-server" );
    expect( rewrite( "h.exe --no-proxy-server", 0, NULL, &how ),
            "h.exe --no-proxy-server --disable-features=PartitionAllocBackupRefPtr --single-process" );
    if (how & SC_NOPROXY_ADDED) FAIL("--no-proxy-server doubled\n");
    {
        WCHAR out[64];
        int cll;
        WCHAR *wc = w( "h.exe --lang=en", &cll );
        if (sc_browser_cmdline( wc, cll, 1, "--a-long-extra-switch", out, 64, &how ) != -1) FAIL("small buffer accepted\n");
    }
    printf("PASS: browser command line: BRP off in its last --disable-features list (or a new one), "
           "--single-process, jitless unless asked otherwise, --no-proxy-server unless it has a proxy switch, extra flags "
           "appended, nothing doubled\n");

    /* madeira-bcd: a --js-flags= in MADEIRA_SC_CEF_FLAGS keeps --jitless (sc_extra_js_flags) */
    {
        const char *r;
        r = rewrite( "h.exe --lang=en", 1, "--js-flags=--max-semi-space-size=1 --enable-low-end-device-mode", &how );
        expect( r, "h.exe --lang=en --disable-features=PartitionAllocBackupRefPtr --single-process --no-proxy-server "
                   "--js-flags=--jitless\" \"--max-semi-space-size=1 --enable-low-end-device-mode" );
        if (how != (SC_BRP_NEW | SC_SINGLE_ADDED | SC_NOPROXY_ADDED | SC_EXTRA_ADDED | SC_JITLESS_MERGED)) FAIL("merge how=%x\n", how);
        expect( last_js_flags( r ), "--js-flags=--jitless --max-semi-space-size=1" );
        r = rewrite( "h.exe", 1, "--js-flags=\"--max-semi-space-size=1 --optimize-for-size\" --x", &how );
        expect( r, "h.exe --disable-features=PartitionAllocBackupRefPtr --single-process --no-proxy-server "
                   "--js-flags=\"--jitless --max-semi-space-size=1 --optimize-for-size\" --x" );
        expect( last_js_flags( r ), "--js-flags=--jitless --max-semi-space-size=1 --optimize-for-size" );
        r = rewrite( "h.exe", 1, "--x --js-flags=", &how );
        expect( last_js_flags( r ), "--js-flags=--jitless" );
        if (!(how & SC_JITLESS_MERGED) || (how & SC_JITLESS_ADDED)) FAIL("empty value how=%x\n", how);
        r = rewrite( "h.exe", 1, "--js-flags=--a --js-flags=\"--b --c\"", &how );   /* Chromium keeps the last one */
        expect( r, "h.exe --disable-features=PartitionAllocBackupRefPtr --single-process --no-proxy-server "
                   "--js-flags=--a --js-flags=\"--jitless --b --c\"" );
        expect( last_js_flags( r ), "--js-flags=--jitless --b --c" );
        r = rewrite( "h.exe --js-flags=--app-own", 1, "--js-flags=--max-old-space-size=96", &how );
        expect( last_js_flags( r ), "--js-flags=--jitless --max-old-space-size=96" );
        if (how != (SC_BRP_NEW | SC_SINGLE_ADDED | SC_NOPROXY_ADDED | SC_EXTRA_ADDED | SC_JITLESS_MERGED | SC_OWN_JS_FLAGS))
            FAIL("own + extra how=%x\n", how);
        r = rewrite( "h.exe", 0, "--js-flags=--max-semi-space-size=1", &how );   /* MADEIRA_JITLESS=0: verbatim */
        expect( last_js_flags( r ), "--js-flags=--max-semi-space-size=1" );
        if (how & (SC_JITLESS_MERGED | SC_JITLESS_ADDED)) FAIL("jitless off how=%x\n", how);
        r = rewrite( "h.exe", 1, "--no-js-flags=--x a--js-flags=--y", &how );   /* look-alikes: our own switch */
        expect( r, "h.exe --disable-features=PartitionAllocBackupRefPtr --single-process --js-flags=--jitless "
                   "--no-proxy-server --no-js-flags=--x a--js-flags=--y" );
        if (!(how & SC_JITLESS_ADDED) || (how & SC_JITLESS_MERGED)) FAIL("look-alike how=%x\n", how);
        expect( last_js_flags( r ), "--js-flags=--jitless" );
        expect( last_js_flags( rewrite( cl, 1, "--enable-low-end-device-mode", &how ) ), "--js-flags=--jitless" );
        {
            /* the caller's buffer (cl_len + 160 + strlen(extra)) always holds the merge */
            static const char *const extras[] = { "--js-flags=", "--js-flags=\"\"", "--js-flags=--a",
                                                  "--js-flags=\"--a\" --js-flags=--b --js-flags=" };
            unsigned e;
            for (e = 0; e < sizeof(extras) / sizeof(extras[0]); e++)
            {
                WCHAR out[512];
                int cll;
                WCHAR *wc = w( "h.exe", &cll );
                int cap = cll + 160 + (int)strlen( extras[e] );
                int n = sc_browser_cmdline( wc, cll, 1, extras[e], out, cap, &how );
                if (n < 0 || n >= cap) FAIL("caller's buffer too small for [%s]\n", extras[e]);
                if (strncmp( last_js_flags( a( out, n ) ), "--js-flags=--jitless", 20 )) FAIL("[%s] lost jitless\n", extras[e]);
            }
        }
    }
    printf("PASS: a --js-flags= in MADEIRA_SC_CEF_FLAGS gets --jitless first (quoted, bare, empty, repeated, next to the "
           "app's own); Windows' splitting reads it as one argument; MADEIRA_JITLESS=0 leaves it verbatim\n");

    if (!ios_sc_cef_refuse( "libcef.dll", 1, 0, 1, 0 ) || !ios_sc_cef_refuse( "LIBCEF.DLL", 1, 0, 1, 0 )) FAIL("client libcef\n");
    if (ios_sc_cef_refuse( "libcef.dll", 1, 1, 1, 0 )) FAIL("helper refused\n");
    if (ios_sc_cef_refuse( "libcef.dll", 0, 0, 1, 0 )) FAIL("MADEIRA_SC_CEF=0 refused\n");
    if (ios_sc_cef_refuse( "libcef.dll", 1, 0, 0, 0 )) FAIL("non-Social Club process (Steam) refused\n");
    if (ios_sc_cef_refuse( "libcef.dll.bak", 1, 0, 1, 0 ) || ios_sc_cef_refuse( NULL, 1, 0, 1, 0 )) FAIL("other names\n");
    if (!ios_sc_cef_refuse( "nvngx_dlss.dll", 1, 0, 1, 0 ) || !ios_sc_cef_refuse( "NVNGX_DLSSG.DLL", 1, 0, 1, 0 ))
        FAIL("client DLSS runtime\n");
    if (ios_sc_cef_refuse( "nvngx_dlss.dll", 1, 0, 0, 0 ) || ios_sc_cef_refuse( "nvngx_dlss.dll", 0, 0, 1, 0 ) ||
        ios_sc_cef_refuse( "nvngx_dlss.dll", 1, 1, 1, 0 )) FAIL("DLSS refused outside a Social Club client\n");
    if (ios_sc_cef_refuse( "libcef.dll", 1, 0, 1, 1 ) || !ios_sc_cef_refuse( "nvngx_dlss.dll", 1, 0, 1, 1 ))
        FAIL("MADEIRA_SC_GAME_CEF=1\n");
    {
        static int name;
        if (!ios_resource_only_map( 2, NULL )) FAIL("resource-only map of a refused image\n");
        if (ios_resource_only_map( 2, &name )) FAIL("loader map (ArbitraryUserPointer set) taken for resource-only\n");
        if (ios_resource_only_map( 1, NULL ) || ios_resource_only_map( 0, NULL )) FAIL("exhausted / not refused\n");
    }
    if (ios_sc_cef_refuse( "sl.dlss.dll", 1, 0, 1, 0 ) || ios_sc_cef_refuse( "nvngx_dlssd.dll.x", 1, 0, 1, 0 ))
        FAIL("Streamline's own plugin refused\n");
    {
        int len;
        WCHAR *p = w( helper, &len );
        if (!ios_sc_path_is_helper( p, len )) FAIL("helper path\n");
        p = w( "C:\\Grand Theft Auto V Enhanced\\GTA5_Enhanced.exe", &len );
        if (ios_sc_path_is_helper( p, len )) FAIL("game path\n");
        p = w( "SocialClubHelper.exe", &len );
        if (!ios_sc_path_is_helper( p, len )) FAIL("bare name\n");
    }
    printf("PASS: libcef.dll and nvngx_dlss(g).dll are refused only in a Social Club client that is not the helper, switch on\n");
}

/* V8 14 sandbox.cc DetermineAddressSpaceLimit on Windows x64: min(CPUID bits - 1, the power of two at or
 * above lpMaximumApplicationAddress + 1), 48 bits when out of [36, 64] */
static uint64_t v8_address_space_limit( uint64_t highest, unsigned cpuid_bits )
{
    uint64_t end = highest + 1;
    unsigned sw = 64 - __builtin_clzll( end - 1 ), hw = cpuid_bits - 1, bits = sw < hw ? sw : hw;
    if (bits < 36 || bits > 64) bits = 48;
    return 1ull << bits;
}

static void address_limit( void )
{
    const uint64_t clamped = 0x7fffffffffull, tb = 1ull << 40, sandbox = tb, min_reserve = 8ull << 30;
    uint64_t told = ios_sc2_reported_highest( clamped, 0, 2, 1 ), limit, reserve, steps = 0;

    if (told != IOS_SC2_WIDE_HIGHEST || told != 0x1ffffffffffull) FAIL("helper told 0x%llx\n", (unsigned long long)told);
    if (ios_sc2_reported_highest( clamped, 0, 2, 0 ) != clamped) FAIL("the game widened\n");
    if (ios_sc2_reported_highest( clamped, 0, 1, 1 ) != clamped || ios_sc2_reported_highest( clamped, 0, 0, 1 ) != clamped)
        FAIL("widened outside layout 2\n");
    if (ios_sc2_reported_highest( 0x7ffeffff, 1, 2, 1 ) != 0x7ffeffff) FAIL("a WoW64 guest limit widened\n");
    if (ios_sc2_reported_highest( 0x7ffffffeffffull, 0, 2, 1 ) != 0x7ffffffeffffull) FAIL("MADEIRA_WIDE_USER_VA narrowed\n");
    /* the wall: 512 GB fails V8's CHECK_LT(kSandboxSize, address_space_limit) */
    if (v8_address_space_limit( clamped, 48 ) != 512ull << 30 || sandbox < v8_address_space_limit( clamped, 48 ))
        FAIL("model: the clamped limit should fail V8's CHECK\n");
    limit = v8_address_space_limit( told, 48 );   /* FEX CPUID 0x80000008: 48 linear address bits */
    if (limit != 2 * tb || !(sandbox < limit)) FAIL("told 2 TB: limit 0x%llx\n", (unsigned long long)limit);
    reserve = limit / 4 < sandbox ? limit / 4 : sandbox;
    if (reserve != 512ull << 30) FAIL("max reservation 0x%llx\n", (unsigned long long)reserve);
    if (reserve >= sandbox) FAIL("a fully reserved sandbox would be tried\n");
    for (; reserve >= min_reserve; reserve /= 2) steps++;
    if (steps != 7) FAIL("%llu partially reserved steps\n", (unsigned long long)steps);
    /* InitializeAsPartiallyReservedSandbox keeps a base <= limit / 2 (else frees it and retries) */
    if (IOS_SC2_CAGE_BASE > limit / 2) FAIL("V8 would free the cage: it wants a base <= 0x%llx\n",
                                            (unsigned long long)(limit / 2));
    printf("PASS: layout 2 tells SocialClubHelper.exe alone HighestUserAddress 0x%llx: V8's limit 2^%d passes its 1 TB "
           "CHECK (the clamped 512 GB fails it); partially reserved sandbox 512 GB -> 8 GB in 7 steps\n",
           (unsigned long long)told, 64 - __builtin_clzll( limit ) - 1);
}

/* the boot half runs once per process, so each case is its own run of this binary */
static void not_opted_in( void )
{
    mach_vm_address_t addr = 0x7c00000000ull;
    SIZE_T size = 0x400000000ull, sz;
    void *pick;

    if (ios_sc_pa_hold_arena( &addr, &size ) || nvm || addr != 0x7c00000000ull) FAIL("arena moved without the switch\n");
    if (ios_sc_glued_pools( &pick, &sz, 0x2000, 1 ) != STATUS_NO_MEMORY || calls || nvm) FAIL("granted without the switch\n");
    printf("PASS: without env.MADEIRA_SC_PA_POOLS=1 the FEX arena stays at its old place and nothing is granted\n");
}

static void move_fails( void )
{
    mach_vm_address_t addr = 0x7c00000000ull;
    SIZE_T size = 0x400000000ull;

    vm_add( 0x7f00000000ull, 0x10000 );   /* something already inside the 12 GB */
    if (ios_sc_pa_hold_arena( &addr, &size ) || nvm != 1 || ios_sc_brp_layout || ios_sc_brp_held)
        FAIL("failed move left something held\n");
    printf("PASS: a move that cannot be mapped holds nothing and leaves the arena where it was\n");
}

static void opted_in( void )
{
    mach_vm_address_t addr = 0x7c00000000ull;
    SIZE_T size = 0x400000000ull, sz;
    void *pick;

    if (!ios_sc_pa_hold_arena( &addr, &size ) || addr != 0x7d00000000ull || size != 0x300000000ull)
        FAIL("arena not moved to 0x7d00000000+12GB\n");
    if (!ios_sc_brp_held || !ios_sc_brp_layout || nvm != 2 || !vm_overlaps( 0x7c00000000ull, 0x100000000ull ))
        FAIL("4 GB not held\n");
    if (ios_sc_pa_hold_arena( &addr, &size )) FAIL("boot half ran twice\n");
    if (ios_sc_glued_pools( &pick, &sz, 0x2000, 1 ) || (uintptr_t)pick != 0x7800000000ull || sz != 0x800000000ull)
        FAIL("helper grant\n");
    if (ios_sc_brp_held || nvm != 2) FAIL("hold not turned into the grant\n");
    /* a second helper while the first one's view is alive: falls back, the range stays the first one's */
    if (ios_sc_glued_pools( &pick, &sz, 0x2000, 1 ) != STATUS_CONFLICTING_ADDRESSES) FAIL("taken range granted\n");
    if (ios_sc_brp_held) FAIL("hold taken over a live grant\n");
    /* the first helper's view goes away: the next helper gets the range again */
    vm_del( 0x7800000000ull );
    if (ios_sc_glued_pools( &pick, &sz, 0x2000, 1 ) || (uintptr_t)pick != 0x7800000000ull) FAIL("restarted helper\n");
    /* something else sits in the regular pool's range: the hold comes back for a later try */
    vm_del( 0x7800000000ull );
    vm_add( 0x7900000000ull, 0x10000 );
    if (ios_sc_glued_pools( &pick, &sz, 0x2000, 1 ) != STATUS_CONFLICTING_ADDRESSES || !ios_sc_brp_held)
        FAIL("blocked grant did not put the hold back\n");
    ios_sc_pa_drop_hold();
    if (ios_sc_brp_held || ios_sc_brp_layout || vm_overlaps( 0x7c00000000ull, 0x100000000ull )) FAIL("drop_hold\n");
    printf("PASS: env.MADEIRA_SC_PA_POOLS=1: arena at 0x7d00000000 (12 GB) with 0x7c00000000+4GB held; the helper "
           "gets 32 GB at 0x7800000000 with 20 GB really reserved; a blocked range puts the hold back; a restarted "
           "helper gets it again\n");
}

static void layout2( void )   /* the Oilpan 4 GB is held by ios_sc2_boot_holds, not here */
{
    mach_vm_address_t addr = 0x7c00000000ull;
    SIZE_T size = 0x400000000ull;

    if (!ios_sc_pa_hold_arena( &addr, &size ) || addr != 0x7d00000000ull || size != 0x300000000ull)
        FAIL("layout 2: arena not moved\n");
    if (ios_sc_brp_held || !ios_sc_brp_layout || nvm != 1) FAIL("layout 2: held the 4 GB here\n");
    ios_sc_pa_drop_hold();
    if (nvm != 1) FAIL("layout 2: drop_hold released a hold it does not own\n");
    printf("PASS: env.MADEIRA_SC_PA_POOLS=2 with the alias at 0x7900000000: the arena moves, the 4 GB is left to "
           "layout 2; with the alias elsewhere it is layout 1\n");
}

int main( int argc, char **argv )
{
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp( mode, "gate" )) { gate_and_cmdline(); address_limit(); }
    else if (!strcmp( mode, "off" )) not_opted_in();
    else if (!strcmp( mode, "move-fails" )) move_fails();
    else if (!strcmp( mode, "on" )) opted_in();
    else if (!strcmp( mode, "on2" )) layout2();
    else FAIL("mode?\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as t:
    c = Path(t) / 'sc.c'
    c.write_text(harness)
    exe = Path(t) / 'sc'
    subprocess.run(['cc', '-std=gnu11', '-O1', '-Wall', '-Wno-unused-function', '-fsanitize=address,undefined',
                    '-fno-sanitize-recover=all', str(c), '-o', str(exe)], check=True)
    base_env = {k: v for k, v in os.environ.items() if not k.startswith('MADEIRA_')}
    for mode, pools in (('gate', None), ('off', None), ('off', '0'), ('move-fails', '1'), ('on', '1'),
                        ('on2', '2'), ('on', '2-alias-elsewhere'), ('on2', '2-pool-low')):
        env = {k: v for k, v in base_env.items() if not k.startswith('WINE_IOS_JIT_')}
        if pools == '2':
            env['WINE_IOS_JIT_RW'] = '7900000000'
            env['WINE_IOS_JIT_SIZE'] = '38000000'
        if pools == '2-pool-low':
            # madeira-bcd pool-low: region C's alias opens the reservation at 0x7900000000,
            # the pool's own alias sits 0x1a000000 above it
            pools = '2'
            env['WINE_IOS_JIT_RX'] = '148000000'
            env['WINE_IOS_JIT_RW'] = '791a000000'
            env['WINE_IOS_JIT_SIZE'] = '38000000'
            env['WINE_IOS_JIT_TAIL_REGION'] = '12e000000:12000000'
        if pools == '2-alias-elsewhere':
            pools = '2'
            env['WINE_IOS_JIT_RW'] = '7000000000'
            env['WINE_IOS_JIT_SIZE'] = '38000000'
        if pools is not None:
            env['MADEIRA_SC_PA_POOLS'] = pools
        out = subprocess.run([str(exe), mode], capture_output=True, text=True, env=env)
        print(out.stdout, end='')
        assert out.returncode == 0, (mode, pools, out.stdout + out.stderr)
