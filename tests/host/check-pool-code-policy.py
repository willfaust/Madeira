#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""env.MADEIRA_POOL_CODE_FOREGROUND = 1: FEX code buffers favour the program being played (virtual_ios.c pool-fg).

With the switch and a usable MADEIRA_GAME_FOLDER, ios_pool_fg_class classes each process as the game (an image inside the
folder, or only the one env.MADEIRA_POOL_CODE_FOREGROUND_PROGRAM names) or another program. Another program's code buffers
are at most 16 MB, and a buffer the game freed or left behind is held for it for 120 s, so Ubisoft Connect does not take the
buffer a relaunched Far Cry 4 needs.

Checks:
  1. ios_pool_fg_class and the pool-code-policy-test region, with a scripted TEB/PEB per process: OFF unless the switch is
     exactly "1" and MADEIRA_GAME_FOLDER is usable (set, not a drive root, ASCII, not too long); GAME for an image inside the
     folder (ASCII case ignored, '/' and '\\' alike, a separator must follow: "Far Cry 3" does not hold "Far Cry 3 Blood
     Dragon"), else OTHER (also with no TEB or no process parameters); with env.MADEIRA_POOL_CODE_FOREGROUND_PROGRAM only that
     file name inside the folder is GAME, and a name with a separator or outside ASCII matches nothing; both variables read at
     each call; one [pool-fg] line per process; the hold ends at exactly 120 s;
  2. the real EC_CODE allocation prefix, MEM_RELEASE carve block, merge, cut and exit retire on a model of the pool
     (-Wall -Wextra -Werror, and ASan + UBSan): another program is clamped to 16 MB before the budget (no cap lift, and region
     C's room does not lift it) and gets a 16 MB piece of a free 128 MB carve, while the game, and everyone with the policy
     off, gets the lift; a carve the game freed is held from other programs for 120 s, also across a merge, and a spent hold
     is not renewed; a new or reused carve takes its holder's class; Far Cry 4 relaunched through Ubisoft Connect gets its
     128 MB back (with the switch unset upc.exe takes it and the game starts on 16 MB);
  3. wiring: every new carve of the tail and region C paths takes the caller's class; both keys in the catalog and cleared at
     the session end with MADEIRA_GAME_FOLDER; the app publishes the game folder; Ubisoft Connect's list sets the program key.
Not covered: the app's launch paths beyond the lines that publish the folder; reading a live PEB; fresh tail placement (a
model: bump down from the pool's end, no holes); thread scans (stubs); the log text beyond the [pool-fg] count.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[-3000:]) if detail and not cond else ""))
    ok = ok and bool(cond)


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


def region(name):
    begin, end = f"/* {name}:begin", f"/* {name}:end */"
    return src[src.index(begin):src.index(end) + len(end)] + "\n"


def define(name):
    return next(line for line in src.splitlines() if line.startswith("#define " + name + " ")) + "\n"


ec = src[src.index("size_t alloc_size = (*size_ptr + 0x3FFF) & ~0x3FFFUL;"):]
ec = ec[:ec.index("size_t reserve_offset, tail_added, tail_skipped = 0;")]
free_start = src.index("    if ((type & MEM_RELEASE) && ios_jit_rx_base_global && ios_jit_pool_size_global &&")
release_block = src[free_start:src.index("\n    }\n", src.index("/* pool address but not a live tail carve", free_start)) + 7]
carve_table = src[src.index("#define IOS_TAIL_CARVE_MAX "):]
carve_table = carve_table[:carve_table.index("\n\n")] + "\n"
fg_class = cut(src, "enum { IOS_POOL_FG_OFF = 0")
helpers = "".join(cut(src, s) for s in (
    "static size_t ios_pool_hole_between(", "static size_t ios_pool_code_cap(", "int ios_jit_low_contains(",
    "static int ios_pool_low_take(", "static int ios_tail_carve_in_low(", "static int ios_pool_preserve_code_carve(", "static int ios_pool_preserve_big_carve(",
    "static int ios_tail_carve_ready(", "static unsigned ios_tail_carves_retire_owner(",
    "static int ios_tail_carve_foreign_release(", "static void ios_tail_carves_owner_died("))

fixture = r'''
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#define MB ((size_t)1 << 20)
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
enum { STATUS_NO_MEMORY = -1, STATUS_SUCCESS = 0, FALLBACK_TAIL = 2, FALL_THROUGH = 3, MEM_RELEASE = 0x8000 };
#define POOL (512 * MB)
#define LOW (64 * MB)
#define FC4_DIR "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Far Cry 4"
#define FC4_EXE FC4_DIR "\\bin\\FarCry4.exe"
#define UC_DIR "C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher"
#define UPC_EXE UC_DIR "\\upc.exe"
''' + define("IOS_POOL_LOW_CARVE_MAX") + define("IOS_POOL_REUSE_GRACE_SEC") + r'''
static time_t fake_now;
static time_t fake_time(time_t *t) { if (t) *t = fake_now; return fake_now; }
#define time(t) fake_time(t)
static int fg_lines;
static char fg_last[512];
static int fixture_log(int fd, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static int fixture_log(int fd, const char *fmt, ...)   /* the allocator's log: counted, then to stderr */
{
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (strstr(line, "[pool-fg]")) { fg_lines++; strcpy(fg_last, line); }
    (void)fd;
    return fputs(line, stderr);
}
#define dprintf fixture_log
typedef uint16_t WCHAR; typedef uint32_t ULONG; typedef void *HANDLE;
typedef struct { uint16_t Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
typedef struct { HANDLE UniqueProcess, UniqueThread; } CLIENT_ID;
typedef struct { PEB *Peb; CLIENT_ID ClientId; } TEB;
#define HandleToULong(h) ((ULONG)(uintptr_t)(h))
static void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
uintptr_t ios_jit_low_rx_global, ios_jit_low_rw_global;
size_t ios_jit_low_size_global;
static size_t ios_jit_pool_size_global, jit_pool_offset, ios_pool_head_reserve;
static volatile size_t ios_jit_low_reserved, ios_jit_tail_reserved;
static size_t ios_jit_hole_off_eff, ios_jit_hole_end_eff, ios_jit_hole2_off, ios_jit_hole2_end;
static int ios_jit_low_full_logged;
static unsigned ios_tail_carve_n;
static pthread_mutex_t ios_tail_carve_lock = PTHREAD_MUTEX_INITIALIZER;
''' + carve_table + r'''
struct proc { TEB teb; PEB peb; RTL_USER_PROCESS_PARAMETERS pp; WCHAR path[128]; };
static TEB *cur;                                    /* the calling thread's TEB */
static TEB *ios_jit_current_teb(void) { return cur; }
static void *ios_jit_current_peb(void) { return cur ? (void *)cur->Peb : NULL; }
static uintptr_t ios_wow_base(void) { return 0; }
static int ios_tail_carve_scan(const void *b, size_t s, int strict) { (void)b; (void)s; (void)strict; return 0; }
static int ios_tail_carve_occupied(const void *b, size_t s) { (void)b; (void)s; return 0; }
''' + region("pool-code-policy-test") + fg_class + helpers + region("pool-carve-merge-test") + \
    cut(src, "static int ios_pool_carve_merge_enabled(") + r'''
static int tail_fg;
static int allocate(size_t *size_ptr, void **ret)
{
''' + ec + r'''
    (void)kept_big_carve;  /* read by the production tail path after this prefix */
    tail_fg = carve_fg;     /* the production tail path gives its new carve .fg = carve_fg (pinned below) */
    return FALLBACK_TAIL;
}
static int release(void *base, unsigned type, void **addr_ptr, size_t *size_ptr)
{
''' + release_block + r'''
    return FALL_THROUGH;
}

static char *pool, *low;
static size_t got;

static int tail_carve(size_t *size_ptr, void **ret)   /* model of the tail path: right below the last carve */
{
    size_t size = (*size_ptr + 0x3fff) & ~(size_t)0x3fff;
    if (ios_jit_tail_reserved + size > POOL - jit_pool_offset) return STATUS_NO_MEMORY;
    ios_jit_tail_reserved += size;
    CHECK(ios_tail_carve_n < IOS_TAIL_CARVE_MAX);
    ios_tail_carves[ios_tail_carve_n++] = (struct ios_tail_carve){ .off = POOL - ios_jit_tail_reserved, .size = size,
                                                                   .peb = ios_jit_current_peb(), .fg = tail_fg };
    *ret = pool + POOL - ios_jit_tail_reserved;
    *size_ptr = size;
    return STATUS_SUCCESS;
}
static int ask1(struct proc *p, size_t size, void **rx)   /* one request; the size granted in `got` */
{
    int status;
    cur = &p->teb;
    status = allocate(&size, rx);
    if (status == FALLBACK_TAIL) status = tail_carve(&size, rx);
    got = size;
    return status;
}
static size_t fex_ask(struct proc *p, size_t want, void **rx)   /* FEX's CodeBuffer: halve on refusal */
{
    size_t size;
    for (size = want; size >= 0x4000; size >>= 1)
        if (ask1(p, size, rx) == STATUS_SUCCESS) return got;
    return 0;
}
static void give_back(struct proc *p, void *rx, size_t size)
{
    void *addr = NULL;
    size_t freed = 0;
    cur = &p->teb;
    CHECK(release(rx, MEM_RELEASE, &addr, &freed) == STATUS_SUCCESS && addr == rx && freed == size);
}
static size_t off_of(const void *rx) { return (size_t)((const char *)rx - pool); }
static struct ios_tail_carve *at(const void *rx)   /* the entry that starts at rx */
{
    unsigned i = 0;
    while (i < ios_tail_carve_n && ios_tail_carves[i].off != off_of(rx)) i++;
    CHECK(i < ios_tail_carve_n);
    return &ios_tail_carves[i];
}
static void make(struct proc *p, unsigned pid, const char *image)
{
    size_t k, len = strlen(image);
    memset(p, 0, sizeof(*p));
    CHECK(len < sizeof(p->path) / sizeof(p->path[0]));
    for (k = 0; k < len; k++) p->path[k] = (unsigned char)image[k];
    p->pp.ImagePathName.Buffer = p->path;
    p->pp.ImagePathName.Length = (uint16_t)(len * sizeof(WCHAR));
    p->peb.ProcessParameters = &p->pp;
    p->teb.Peb = &p->peb;
    p->teb.ClientId.UniqueProcess = (HANDLE)(uintptr_t)pid;
}
static void reset(const char *policy)
{
    ios_jit_low_rx_global = ios_jit_low_rw_global = (uintptr_t)low;
    ios_jit_low_size_global = ios_jit_low_reserved = LOW;   /* region C full */
    ios_jit_rx_base_global = ios_jit_rw_base_global = pool;
    ios_jit_pool_size_global = POOL;
    jit_pool_offset = 128 * MB;                 /* with 48 MB of headroom the budget allows 128 MB */
    ios_pool_head_reserve = 48 * MB;
    ios_jit_tail_reserved = ios_tail_carve_n = 0;
    memset(ios_tail_carves, 0, sizeof(ios_tail_carves));
    fake_now = 1000;
    unsetenv("MADEIRA_POOL_CARVE_MERGE");
    if (policy) setenv("MADEIRA_POOL_CODE_FOREGROUND", policy, 1);
    else unsetenv("MADEIRA_POOL_CODE_FOREGROUND");
    setenv("MADEIRA_GAME_FOLDER", FC4_DIR, 1);
}
static void free_128_at_floor(void)   /* a ready free 128 MB carve; the budget at its 16 MB floor */
{
    ios_tail_carves[0] = (struct ios_tail_carve){ .off = POOL - 128 * MB, .size = 128 * MB, .free = 1, .freed_at = 900 };
    ios_tail_carve_n = 1;
    ios_jit_tail_reserved = 128 * MB;
    jit_pool_offset = POOL - 128 * MB - 48 * MB - 20 * MB;
}
static struct proc game, upc, fc4b;
static int class_of(TEB *teb) { cur = teb; return ios_pool_fg_class(); }

/* env.MADEIRA_POOL_CODE_FOREGROUND_PROGRAM: Ubisoft Connect from the library, whose helpers live in its own folder. */
static void program_rule(void)
{
    static const char *const nothing[] = { "x\\upc.exe", "u/pc.exe", "upc.ex", "pc.exe", "\xc3\xbcpc.exe" };
    static struct proc client, service, renderer, other_upc, longer;
    unsigned k;

    make(&client, 0x3b0, UPC_EXE);
    make(&service, 0x3b4, UC_DIR "\\UplayService.exe");
    make(&renderer, 0x3b8, UC_DIR "\\UplayWebCore.exe");
    make(&other_upc, 0x3bc, "C:\\Other\\upc.exe");
    make(&longer, 0x3c0, UC_DIR "\\xupc.exe");
    setenv("MADEIRA_GAME_FOLDER", UC_DIR, 1);
    unsetenv("MADEIRA_POOL_CODE_FOREGROUND_PROGRAM");
    CHECK(class_of(&client.teb) == IOS_POOL_FG_GAME && class_of(&service.teb) == IOS_POOL_FG_GAME);
    setenv("MADEIRA_POOL_CODE_FOREGROUND_PROGRAM", "", 1);
    CHECK(class_of(&service.teb) == IOS_POOL_FG_GAME && class_of(&renderer.teb) == IOS_POOL_FG_GAME);
    setenv("MADEIRA_POOL_CODE_FOREGROUND_PROGRAM", "upc.exe", 1);
    CHECK(class_of(&client.teb) == IOS_POOL_FG_GAME);
    CHECK(class_of(&service.teb) == IOS_POOL_FG_OTHER && class_of(&renderer.teb) == IOS_POOL_FG_OTHER);
    CHECK(class_of(&other_upc.teb) == IOS_POOL_FG_OTHER && class_of(&longer.teb) == IOS_POOL_FG_OTHER);
    CHECK(class_of(NULL) == IOS_POOL_FG_OTHER);
    setenv("MADEIRA_POOL_CODE_FOREGROUND_PROGRAM", "UPC.EXE", 1);
    CHECK(class_of(&client.teb) == IOS_POOL_FG_GAME && class_of(&service.teb) == IOS_POOL_FG_OTHER);
    for (k = 0; k < sizeof(nothing) / sizeof(nothing[0]); k++)
    {
        setenv("MADEIRA_POOL_CODE_FOREGROUND_PROGRAM", nothing[k], 1);
        CHECK(class_of(&client.teb) == IOS_POOL_FG_OTHER && class_of(&service.teb) == IOS_POOL_FG_OTHER);
    }
    CHECK(ios_pool_path_is_program(client.path, client.pp.ImagePathName.Length / sizeof(WCHAR), "upc.exe") && !ios_pool_path_is_program(NULL, 0, "upc.exe"));
    unsetenv("MADEIRA_POOL_CODE_FOREGROUND_PROGRAM");
    puts("PASS: with a program named, only that program of the folder is the game (its file name, ASCII case ignored); the "
         "folder's other programs, the same name elsewhere and a name with a separator or outside ASCII are not; unset or "
         "empty keeps the folder rule");
}

static void classes(void)
{
    static const char *const off[] = { "", "0", "11", "1 ", " 1", "true" };
    static const char *const unusable[] = { "", "C:", "C:\\", "C:/", "\\", "C:\\Spiele\\F\xc3\xa4rcry 3" };
    static const char *const folders[] = { "C:\\Games\\Far Cry 3", "C:\\Games\\Far Cry 3\\", "c:/games/FAR CRY 3//" };
    static struct proc fc3, fc3b, bd, bare, nopp, wide;
    char longdir[1100];
    unsigned k;
    int lines;

    CHECK(IOS_POOL_OTHER_MAX == 16 * MB && IOS_POOL_FG_HOLD_SEC == 120);
    CHECK(ios_pool_game_folder_len("C:\\Games\\Far Cry 3\\/\\") == 18 && !ios_pool_game_folder_len(NULL));
    CHECK(!ios_pool_fg_held(0, 1, 100, 101) && !ios_pool_fg_held(1, 0, 100, 101));
    CHECK(ios_pool_fg_held(1, 1, 100, 219) && !ios_pool_fg_held(1, 1, 100, 220));
    make(&fc3, 0x300, "C:\\Games\\Far Cry 3\\bin\\farcry3_d3d11.exe");
    make(&fc3b, 0x304, "c:/GAMES/far cry 3/bin/FC3Updater.exe");
    make(&bd, 0x308, "C:\\Games\\Far Cry 3 Blood Dragon\\bin\\fc3_blooddragon_d3d11.exe");
    make(&bare, 0x30c, "C:\\Games\\Far Cry 3");             /* the folder itself */
    make(&nopp, 0x310, "x");
    nopp.peb.ProcessParameters = NULL;
    make(&wide, 0x314, "C:\\Games\\Far Cry 3\\x.exe");
    wide.path[0] = 0x0143;                                    /* not 'C': only its low byte matches */
    setenv("MADEIRA_GAME_FOLDER", folders[0], 1);
    unsetenv("MADEIRA_POOL_CODE_FOREGROUND");
    CHECK(class_of(&fc3.teb) == IOS_POOL_FG_OFF);
    for (k = 0; k < sizeof(off) / sizeof(off[0]); k++)
    {
        setenv("MADEIRA_POOL_CODE_FOREGROUND", off[k], 1);
        CHECK(class_of(&fc3.teb) == IOS_POOL_FG_OFF && class_of(&bd.teb) == IOS_POOL_FG_OFF);
    }
    setenv("MADEIRA_POOL_CODE_FOREGROUND", "1", 1);
    unsetenv("MADEIRA_GAME_FOLDER");
    CHECK(class_of(&fc3.teb) == IOS_POOL_FG_OFF);
    for (k = 0; k < sizeof(unusable) / sizeof(unusable[0]); k++)
    {
        setenv("MADEIRA_GAME_FOLDER", unusable[k], 1);
        CHECK(class_of(&fc3.teb) == IOS_POOL_FG_OFF && class_of(&bd.teb) == IOS_POOL_FG_OFF);
    }
    memset(longdir, 'a', sizeof(longdir) - 1);
    memcpy(longdir, "C:\\", 3);
    longdir[sizeof(longdir) - 1] = 0;
    setenv("MADEIRA_GAME_FOLDER", longdir, 1);
    CHECK(class_of(&fc3.teb) == IOS_POOL_FG_OFF);
    lines = fg_lines;
    for (k = 0; k < sizeof(folders) / sizeof(folders[0]); k++)
    {
        setenv("MADEIRA_GAME_FOLDER", folders[k], 1);
        CHECK(class_of(&fc3.teb) == IOS_POOL_FG_GAME && class_of(&fc3b.teb) == IOS_POOL_FG_GAME);
        CHECK(class_of(&bd.teb) == IOS_POOL_FG_OTHER && class_of(&bare.teb) == IOS_POOL_FG_OTHER);
        CHECK(class_of(&nopp.teb) == IOS_POOL_FG_OTHER && class_of(&wide.teb) == IOS_POOL_FG_OTHER);
        CHECK(class_of(NULL) == IOS_POOL_FG_OTHER);
    }
    CHECK(fg_lines - lines == 7);                             /* one line per process, however often asked */
    program_rule();
    unsetenv("MADEIRA_POOL_CODE_FOREGROUND");
    CHECK(class_of(&fc3.teb) == IOS_POOL_FG_OFF);
    puts("PASS: the class: only \"1\" with a usable game folder; inside it (case, '/' and '\\' alike, a separator after) "
         "is the game; read at each call; one [pool-fg] line per process");
}

static void other_capped(void)
{
    void *u, *g, *rx;
    make(&upc, 0x110, UPC_EXE);
    make(&game, 0x114, FC4_EXE);
    reset("1");
    CHECK(ask1(&upc, 128 * MB, &rx) == STATUS_NO_MEMORY && ask1(&upc, 32 * MB, &rx) == STATUS_NO_MEMORY);
    CHECK(fex_ask(&upc, 128 * MB, &u) == 16 * MB && u == pool + POOL - 16 * MB && !at(u)->fg);
    CHECK(fex_ask(&game, 128 * MB, &g) == 128 * MB && g == pool + POOL - 144 * MB && at(g)->fg);
    puts("PASS: another program is held to 16 MB before the budget (FEX halves down to it); the game gets 128 MB");

    reset("1");
    free_128_at_floor();
    CHECK(ask1(&upc, 128 * MB, &rx) == STATUS_NO_MEMORY);                         /* no cap lift */
    CHECK(ask1(&upc, 16 * MB, &u) == STATUS_SUCCESS && u == pool + POOL - 16 * MB && got == 16 * MB);
    CHECK(ios_tail_carve_n == 2 && ios_tail_carves[0].free && ios_tail_carves[0].size == 112 * MB);
    CHECK(ios_jit_tail_reserved == 128 * MB && at(u)->peb == &upc.peb && !at(u)->fg);
    give_back(&upc, u, 16 * MB);                                                   /* merges back */
    CHECK(ios_tail_carve_n == 1 && ios_tail_carves[0].size == 128 * MB);
    CHECK(ask1(&game, 128 * MB, &g) == STATUS_SUCCESS && g == pool + POOL - 128 * MB && got == 128 * MB && at(g)->fg);
    reset(NULL);
    free_128_at_floor();
    CHECK(ask1(&upc, 128 * MB, &u) == STATUS_SUCCESS && got == 128 * MB);
    reset("1");
    unsetenv("MADEIRA_GAME_FOLDER");
    free_128_at_floor();
    CHECK(ask1(&upc, 128 * MB, &u) == STATUS_SUCCESS && got == 128 * MB);
    puts("PASS: no cap lift for another program, a 16 MB piece of the free carve instead; the game and the policy off get the lift");

    reset("1");
    ios_jit_low_reserved = 0;                                                        /* region C has room */
    CHECK(ask1(&upc, 64 * MB, &rx) == STATUS_NO_MEMORY && ask1(&upc, 32 * MB, &rx) == STATUS_NO_MEMORY);
    CHECK(fex_ask(&upc, 64 * MB, &u) == 16 * MB && (char *)u >= low && (char *)u < low + LOW && !at(u)->fg);
    CHECK(fex_ask(&game, 64 * MB, &g) == 64 * MB && at(g)->fg);
    reset(NULL);
    ios_jit_low_reserved = 0;
    CHECK(ask1(&upc, 64 * MB, &u) == STATUS_SUCCESS && got == 64 * MB && (char *)u >= low && (char *)u < low + LOW);
    puts("PASS: region C's room does not lift another program's 16 MB; with the policy off a 64 MB request gets it");
}

static void hold(void)
{
    void *g, *u, *rx;
    make(&game, 0x120, FC4_EXE);
    make(&upc, 0x124, UPC_EXE);
    reset("1");
    CHECK(fex_ask(&game, 128 * MB, &g) == 128 * MB);
    give_back(&game, g, 128 * MB);
    fake_now = 1050;
    CHECK(fex_ask(&upc, 16 * MB, &u) == 16 * MB && u == pool + POOL - 144 * MB && at(g)->free && at(g)->size == 128 * MB);
    fake_now = 1060;
    CHECK(fex_ask(&game, 128 * MB, &rx) == 128 * MB && rx == g);
    fake_now = 1070;
    give_back(&game, g, 128 * MB);
    fake_now = 1070 + IOS_POOL_FG_HOLD_SEC - 1;
    CHECK(fex_ask(&upc, 16 * MB, &u) == 16 * MB && u == pool + POOL - 160 * MB);
    fake_now = 1070 + IOS_POOL_FG_HOLD_SEC;
    CHECK(fex_ask(&upc, 16 * MB, &u) == 16 * MB && u == (char *)g + 112 * MB && !at(u)->fg && at(g)->size == 112 * MB);
    puts("PASS: a carve the game freed is not another program's for 120 s; the game takes it back at once");

    make(&game, 0x130, FC4_EXE);
    make(&upc, 0x134, UPC_EXE);
    reset("1");
    CHECK(fex_ask(&game, 128 * MB, &g) == 128 * MB && fex_ask(&upc, 16 * MB, &u) == 16 * MB && u == (char *)g - 16 * MB);
    fake_now = 2000;
    give_back(&game, g, 128 * MB);
    fake_now = 2010;
    give_back(&upc, u, 16 * MB);                     /* another program's release joins the game's carve */
    CHECK(ios_tail_carve_n == 1 && at(u)->size == 144 * MB && at(u)->fg && at(u)->freed_at == 2000);   /* the hold keeps its end */
    fake_now = 2000 + IOS_POOL_FG_HOLD_SEC - 1;
    CHECK(fex_ask(&upc, 16 * MB, &rx) == 16 * MB && rx == pool + POOL - 160 * MB);
    fake_now = 2000 + IOS_POOL_FG_HOLD_SEC;   /* not 120 s after the other program's release */
    CHECK(fex_ask(&upc, 16 * MB, &rx) == 16 * MB && rx == (char *)u + 128 * MB && !at(rx)->fg);

    reset("1");
    ios_tail_carves[0] = (struct ios_tail_carve){ .off = POOL - 16 * MB, .size = 16 * MB, .free = 1, .freed_at = 900 };
    ios_tail_carve_n = 1;
    ios_jit_tail_reserved = 16 * MB;
    CHECK(fex_ask(&game, 16 * MB, &g) == 16 * MB && g == pool + POOL - 16 * MB && at(g)->fg);
    give_back(&game, g, 16 * MB);
    fake_now += IOS_POOL_FG_HOLD_SEC;
    CHECK(fex_ask(&upc, 16 * MB, &u) == 16 * MB && u == g && !at(u)->fg);
    give_back(&upc, u, 16 * MB);
    CHECK(fex_ask(&upc, 16 * MB, &u) == 16 * MB && u == g);
    make(&game, 0x140, FC4_EXE);
    make(&upc, 0x144, UPC_EXE);
    reset("1");
    CHECK(fex_ask(&game, 128 * MB, &g) == 128 * MB);
    fake_now = 3000;
    give_back(&game, g, 128 * MB);
    fake_now = 3000 + IOS_POOL_FG_HOLD_SEC + 80;
    CHECK(fex_ask(&upc, 16 * MB, &u) == 16 * MB && u == (char *)g + 112 * MB && at(g)->fg);   /* the rest keeps its spent mark */
    fake_now += 1;
    give_back(&upc, u, 16 * MB);                     /* joins it again: the spent hold is not renewed */
    CHECK(ios_tail_carve_n == 1 && at(g)->size == 128 * MB && !at(g)->fg);
    fake_now += 10;
    CHECK(fex_ask(&upc, 16 * MB, &rx) == 16 * MB && rx == u);
    puts("PASS: a run keeps the game's hold while it lasts and no longer, and a spent one is not renewed by another program's release; "
         "a reused carve takes its new holder's class");
}

/* Far Cry 4 started from Steam, relaunched by Ubisoft Connect: returns the second FarCry4.exe's buffer. */
static size_t relaunch(const char *policy, unsigned pid)
{
    void *g, *u, *rx;
    size_t got_upc, got_game;
    int lines = fg_lines;
    make(&game, pid, FC4_EXE);
    make(&upc, pid + 4, UPC_EXE);
    make(&fc4b, pid + 8, FC4_EXE);
    reset(policy);
    CHECK(fex_ask(&game, 128 * MB, &g) == 128 * MB);
    jit_pool_offset = POOL - 128 * MB - 48 * MB - 20 * MB;    /* the game's DLLs: the budget at its 16 MB floor */
    fake_now = 1100;
    ios_tail_carves_owner_died(&game.peb);                    /* FarCry4.exe #1 exits */
    CHECK(at(g)->free && at(g)->retired && at(g)->fg == (policy != NULL));
    fake_now = 1122;
    got_upc = fex_ask(&upc, 128 * MB, &u);
    fake_now = 1152;
    got_game = fex_ask(&fc4b, 128 * MB, &rx);
    if (policy)
    {
        CHECK(got_upc == 16 * MB && u == pool + POOL - 144 * MB && got_game == 128 * MB && rx == g);
        CHECK(fg_lines - lines == 3 && strstr(fg_last, "FarCry4.exe"));
    }
    else
        CHECK(got_upc == 128 * MB && u == g && got_game == 16 * MB && rx == pool + POOL - 144 * MB && fg_lines == lines);
    return got_game;
}

int main(void)
{
    void *p = NULL;
    CHECK(!posix_memalign(&p, 0x4000, LOW + POOL));
    low = p;
    pool = low + LOW;
    classes();
    other_capped();
    hold();
    CHECK(relaunch(NULL, 0x200) == 16 * MB);
    puts("PASS: switch unset: upc.exe takes the 128 MB FarCry4.exe #1 left through the cap lift, the game gets 16 MB");
    CHECK(relaunch("1", 0x210) == 128 * MB);
    puts("PASS: switch on: upc.exe gets 16 MB elsewhere within the hold, FarCry4.exe #2 gets the 128 MB back");
    free(p);
    return 0;
}
'''

# 1-2. the class and the allocator, built twice: warnings as errors, then ASan + UBSan
if not cc:
    check("a C compiler for the host test", False)
else:
    with tempfile.TemporaryDirectory(prefix="madeira-pool-code-policy-") as tmp:
        cfile = Path(tmp) / "pool-code-policy.c"
        cfile.write_text(fixture)
        env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_POOL_") and k != "MADEIRA_GAME_FOLDER"}
        base = [cc, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror", "-pthread"]
        for name, flags in (("-Wall -Wextra -Werror, -O2", ["-O2"]),
                            ("ASan + UBSan", ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
                                              "-fno-omit-frame-pointer"])):
            exe = Path(tmp) / ("policy-" + flags[0].strip("-"))
            r = subprocess.run(base + flags + [str(cfile), "-o", str(exe)], capture_output=True, text=True)
            check(f"the fixture compiles ({name})", r.returncode == 0, r.stderr)
            if r.returncode == 0:
                r = subprocess.run([str(exe)], capture_output=True, text=True, env=env)
                print("".join(f"  [{name}] {line}\n" for line in r.stdout.splitlines()), end="")
                check(f"the scenarios pass ({name})", r.returncode == 0, r.stderr)

# 3. wiring
check("every new carve takes the caller's class (region C, ml1039 and tail), a skipped piece none",
      src.count("ios_tail_carves[ios_tail_carve_n].fg = carve_fg;") == 3 and
      src.count("ios_tail_carves[ios_tail_carve_n].fg = 0;") == 1)
gen = (root / "build/tools/gen-config-catalog.py").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text()
lib = (root / "app/Madeira/Library.swift").read_text()
dock = (root / "app/Madeira/MadeiraDock.swift").read_text()
check("the catalog documents the key, off by default; the session end clears it and the game folder",
      re.search(r'"env\.MADEIRA_POOL_CODE_FOREGROUND": \{[^}]*"default": "0"', gen) is not None
      and re.search(r'key: "env\.MADEIRA_POOL_CODE_FOREGROUND"[^\n]*defaultValue: "0"', cat) is not None
      and 'unsetenv("MADEIRA_POOL_CODE_FOREGROUND");' in bridge and 'unsetenv("MADEIRA_GAME_FOLDER");' in bridge)
check("the program key: in the catalog (unset by default), cleared at the session end, set by Ubisoft Connect's list",
      re.search(r'key: "env\.MADEIRA_POOL_CODE_FOREGROUND_PROGRAM"[^\n]*defaultValue: ""', cat) is not None
      and 'unsetenv("MADEIRA_POOL_CODE_FOREGROUND_PROGRAM");' in bridge
      and "env.MADEIRA_POOL_CODE_FOREGROUND_PROGRAM = upc.exe" in (root / "app/Madeira/GameRecommendations.swift").read_text())
check("the app publishes the game folder: a library launch (set or cleared), a Dock start (the game's install folder)",
      'if let gameFolder { setenv("MADEIRA_GAME_FOLDER", gameFolder, 1) } else { unsetenv("MADEIRA_GAME_FOLDER") }' in lib
      and 'return steamAppID != nil ? windowsPath : Self.folder(of: launchWindowsPath)' in lib
      and 'setenv("MADEIRA_GAME_FOLDER", game.windowsInstallPath, 1)' in dock)
print("PASS: pool-code-policy" if ok else "FAILED: pool-code-policy")
sys.exit(0 if ok else 1)
