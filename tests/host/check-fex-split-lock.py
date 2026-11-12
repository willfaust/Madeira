#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""FEX on iOS: a guest atomic whose operand crosses a 16-byte boundary is done inline under a lock
(build/fex-patches/0002-ios-split-lock-atomics-inline.patch).

Needs the FEX submodule (CodeEmitter, FEXCore, FEXHeaderUtils, External/fmt) and a host C++ compiler; no Wine, FEX
build or game.
  1. The patch applies to the pinned FEX's AtomicOps.cpp, after 0001, as apply.sh applies it, and touches nothing else;
     the only lines of FEX's file that go are the seven LSE instructions of AtomicSwap and
     AtomicFetch{Add,Sub,And,CLR,Or,Xor} (CAS, CASPair, AtomicFetchNeg and every LL/SC loop stay as they are).
  2. The patched EmitAtomicRMW, cut from the patched file, compiled on the host with FEX's own emitter for both register
     sets (ARM64EC's TMP1-TMP4 = x10-x13, WOW64's x0-x3), for each operation, size and register layout (the value in
     TMP2, the value register as the destination, the address register as the destination, the guest-window address
     register x24): a byte operand, and every operand with MADEIRA_FEX_SPLIT_LOCK=0, emit exactly the original
     instruction; "", "1" and unset emit the test. With Python's unicorn module (skipped with a note when it is not
     installed), each emitted sequence runs from one state: an aligned operand runs the original instruction alone and
     never touches the lock; a misaligned one inside a 16-byte block reaches the original instruction; a crossing one
     (inside a page and across two pages) gives the old value zero-extended in the destination and the new value in
     memory, writes nothing else, leaves NZCV and every register but TMP1, TMP3, TMP4 and the destination as they were,
     and releases the lock; a crossing operand on an unmapped page faults at the probe with the lock untouched; with the
     lock held elsewhere it gives up after the tries and leaves the operation to the original instruction.
  3. Both FEX builds run apply.sh, the README lists the patch, the catalog documents the switch (on by default) and the
     session end clears it.
NOT covered: building xtajit64.dll / xtajit.dll (the iOS build does), the trap path itself (signal_arm64_ios.c), two
threads at once, and a device run.
"""
from pathlib import Path
import os
import re
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
fex = Path(os.environ.get("FEX_SRC") or (root / "FEX"))
patch_file = root / "build/fex-patches/0002-ios-split-lock-atomics-inline.patch"
ATOMIC = "FEXCore/Source/Interface/Core/JIT/AtomicOps.cpp"
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[:2000]) if detail and not cond else ""))
    ok = ok and bool(cond)


if not (fex / ATOMIC).is_file():
    print("FAIL: the FEX submodule (or FEX_SRC) has " + ATOMIC)
    sys.exit(1)

# ---------------------------------------------------------------- 1. the patch
text = patch_file.read_text()
check("the patch touches AtomicOps.cpp alone", re.findall(r"^diff --git a/(\S+)", text, re.M) == [ATOMIC])
orig = subprocess.run(["git", "-C", str(fex), "show", "HEAD:" + ATOMIC], capture_output=True, text=True).stdout or (fex / ATOMIC).read_text()
with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp) / ATOMIC
    t.parent.mkdir(parents=True)
    t.write_text(orig)
    for earlier in sorted((root / "build/fex-patches").glob("*.patch")):
        if earlier.name < patch_file.name and ATOMIC in earlier.read_text():
            subprocess.run(["git", "apply", str(earlier)], cwd=tmp, check=True)
    base = t.read_text()
    r = subprocess.run(["git", "apply", str(patch_file)], cwd=tmp, capture_output=True, text=True)
    check("the patch applies to the pinned FEX's AtomicOps.cpp (after the patches before it)", r.returncode == 0, r.stderr)
    patched = t.read_text()
    r = subprocess.run(["git", "apply", "--reverse", "--check", str(patch_file)], cwd=tmp, capture_output=True, text=True)
    check("and is then seen as applied (apply.sh skips it)", r.returncode == 0, r.stderr)
orig = base
SITES = ["    ldswpal(SubEmitSize, Src, GetReg(Node), MemSrc);", "    ldaddal(SubEmitSize, Src, GetReg(Node), MemSrc);",
         "    ldaddal(SubEmitSize, TMP2, GetReg(Node), MemSrc);", "    ldclral(SubEmitSize, TMP2, GetReg(Node), MemSrc);",
         "    ldclral(SubEmitSize, Src, GetReg(Node), MemSrc);", "    ldsetal(SubEmitSize, Src, GetReg(Node), MemSrc);",
         "    ldeoral(SubEmitSize, Src, GetReg(Node), MemSrc);"]
gone = [l for l in orig.splitlines() if l not in patched.splitlines()]
check("the only lines of FEX's file that go are the seven LSE instructions", sorted(gone) == sorted(SITES), gone)
for name in ("CAS", "CASPair", "AtomicFetchNeg"):
    body = lambda t: t[t.index("DEF_OP(%s) {" % name):t.index("\n}\n", t.index("DEF_OP(%s) {" % name))]
    check("DEF_OP(%s) is unchanged" % name, body(orig) == body(patched))
check("every LL/SC loop is unchanged", orig.count("ldaxr(") == patched.count("ldaxr(") and orig.count("stlxr(") == patched.count("stlxr("))

# ---------------------------------------------------------------- 2. the emitter, on the host
region = patched[patched.index("// split-lock-test:begin"):patched.index("// split-lock-test:end")]
FIXTURE = r'''
#include <CodeEmitter/Emitter.h>
#include <cstdio>
#include <cstdlib>
namespace FEXCore::Allocator {
void* aligned_alloc(size_t a, size_t s) { return ::aligned_alloc(a, (s + a - 1) / a * a); }
void aligned_free(void* p) { ::free(p); }
}
namespace fextl { void ReportAllocationFailure(size_t, size_t) { abort(); } }
namespace FEXCore::CPU {
#ifdef WOW_TMPS
constexpr auto TMP1 = ARMEmitter::XReg::x0; constexpr auto TMP2 = ARMEmitter::XReg::x1;
constexpr auto TMP3 = ARMEmitter::XReg::x2; constexpr auto TMP4 = ARMEmitter::XReg::x3;
#else
constexpr auto TMP1 = ARMEmitter::XReg::x10; constexpr auto TMP2 = ARMEmitter::XReg::x11;
constexpr auto TMP3 = ARMEmitter::XReg::x12; constexpr auto TMP4 = ARMEmitter::XReg::x13;
#endif
class Arm64Emitter : public ARMEmitter::Emitter {
public:
  using ARMEmitter::Emitter::Emitter;
  void LoadConstant(ARMEmitter::Size s, ARMEmitter::Register Reg, uint64_t C) {
    movz(s, Reg, C & 0xffff, 0);
    for (uint32_t k = 1; k < 4; ++k) if ((C >> (16 * k)) & 0xffff) movk(s, Reg, (C >> (16 * k)) & 0xffff, 16 * k);
  }
};
''' + region + r'''
}
using namespace FEXCore::CPU;
static void hex(const uint32_t* b, size_t n) { for (size_t i = 0; i < n; ++i) printf("%08x", b[i]); }
int main() {
#ifdef FEX_IOS_HOST
  printf("lock %llx\n", (unsigned long long)(uintptr_t)&SplitLockWord);
#endif
  const ARMEmitter::Register V = ARMEmitter::Reg::r5, D = ARMEmitter::Reg::r6, M = ARMEmitter::Reg::r7;
  // value, destination, address: plain; value as destination; the value in TMP2 and the guest-window address register; the
  // address register as the destination
  const ARMEmitter::Register Layout[4][3] = {{V, D, M}, {V, V, M}, {TMP2.R(), D, ARMEmitter::Reg::r24}, {V, M, M}};
  for (int Op = 0; Op < 5; ++Op)
    for (int Size = 0; Size < 4; ++Size)
      for (int L = 0; L < 4; ++L) {
        alignas(16) uint32_t Buf[128] {}, Orig[4] {};
        Arm64Emitter E(reinterpret_cast<uint8_t*>(Buf), sizeof(Buf)), O(reinterpret_cast<uint8_t*>(Orig), sizeof(Orig));
        const auto S = static_cast<ARMEmitter::SubRegSize>(Size);
        EmitAtomicRMW(E, static_cast<SplitLockOp>(Op), S, Layout[L][0], Layout[L][1], Layout[L][2]);
        switch (Op) {
        case 0: O.ldswpal(S, Layout[L][0], Layout[L][1], Layout[L][2]); break;
        case 1: O.ldaddal(S, Layout[L][0], Layout[L][1], Layout[L][2]); break;
        case 2: O.ldclral(S, Layout[L][0], Layout[L][1], Layout[L][2]); break;
        case 3: O.ldsetal(S, Layout[L][0], Layout[L][1], Layout[L][2]); break;
        default: O.ldeoral(S, Layout[L][0], Layout[L][1], Layout[L][2]); break;
        }
        printf("%d %d %d %u %u %u ", Op, Size, L, Layout[L][0].Idx(), Layout[L][1].Idx(), Layout[L][2].Idx());
        hex(Buf, E.GetCursorOffset() / 4);
        printf(" ");
        hex(Orig, O.GetCursorOffset() / 4);
        printf("\n");
      }
}
'''


def build_and_run(tmp, wow, ios=True):
    src = Path(tmp) / "fx.cpp"
    exe = Path(tmp) / ("fx-%d-%d" % (wow, ios))
    src.write_text(FIXTURE)
    inc = ["-I" + str(fex / d) for d in ("CodeEmitter", "FEXCore/include", "FEXHeaderUtils", "External/fmt/include")]
    flags = ["-std=c++20", "-O1", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-unused-const-variable"] + (["-DWOW_TMPS"] if wow else []) + (["-DFEX_IOS_HOST=1"] if ios else [])
    r = subprocess.run([os.environ.get("CXX", "c++"), *flags, *inc, str(src), "-o", str(exe)], capture_output=True, text=True)
    if r.returncode:
        return None, r.stderr
    return exe, ""


def run(exe, value):
    env = {k: v for k, v in os.environ.items() if k != "MADEIRA_FEX_SPLIT_LOCK"}
    if value is not None:
        env["MADEIRA_FEX_SPLIT_LOCK"] = value
    out = subprocess.run([str(exe)], env=env, capture_output=True, text=True, check=True).stdout.split("\n")
    lock = int(out[0].split()[1], 16) if out[0].startswith("lock ") else None
    rows = []
    for line in out[1 if lock is not None else 0:]:
        if line:
            f = line.split()
            rows.append(dict(op=int(f[0]), size=int(f[1]), layout=int(f[2]), v=int(f[3]), d=int(f[4]), m=int(f[5]),
                             code=bytes.fromhex(f[6]), orig=bytes.fromhex(f[7])))
    return lock, rows


def words(b):
    return [int.from_bytes(b[i:i + 4], "big") for i in range(0, len(b), 4)]   # printed big-endian per word


def le(b):
    return b"".join(struct.pack("<I", w) for w in words(b))


try:
    import unicorn
    from unicorn import arm64_const as A
except ImportError:
    unicorn = None

def unlock(b, tmp1):
    """The code with the MOVZ/MOVK words that load the lock's address into TMP1 zeroed: the address differs from run to run."""
    return [0 if (w & 0x7F800000) in (0x52800000, 0x72800000) and (w & 0x1F) == tmp1 else w for w in words(b)]


results = {}
with tempfile.TemporaryDirectory() as tmp:
    for wow in (0, 1):
        tmps = (0, 1, 2, 3) if wow else (10, 11, 12, 13)
        exe, err = build_and_run(tmp, wow)
        check("EmitAtomicRMW compiles with FEX's emitter (%s registers, -Wall -Werror)" % ("WOW64" if wow else "ARM64EC"), exe is not None, err)
        if exe is None:
            continue
        exe_off, err = build_and_run(tmp, wow, ios=False)
        check("and without FEX_IOS_HOST", exe_off is not None, err)
        if exe_off is None:
            continue
        lock, rows = run(exe, None)
        _, rows_off = run(exe, "0")
        _, rows_one = run(exe, "1")
        _, rows_empty = run(exe, "")
        _, rows_zz = run(exe, "00")
        _, rows_noios = run(exe_off, None)
        check("a byte operand emits the original instruction alone", all(r["code"] == r["orig"] for r in rows if r["size"] == 0))
        check("MADEIRA_FEX_SPLIT_LOCK=0, and a build without FEX_IOS_HOST, emit the original instruction alone for every operand",
              all(r["code"] == r["orig"] for r in rows_off + rows_noios))
        check("unset, \"1\", \"\" and \"00\" emit the test for every operand of 2, 4 and 8 bytes",
              all(r["code"] != r["orig"] and len(r["code"]) > 4 for r in rows + rows_one + rows_empty if r["size"] > 0)
              and [unlock(r["code"], tmps[0]) for r in rows] == [unlock(r["code"], tmps[0]) for r in rows_one]
              == [unlock(r["code"], tmps[0]) for r in rows_empty] == [unlock(r["code"], tmps[0]) for r in rows_zz])
        # NZCV and the registers are checked by running the code below; here: where the test falls through
        check("the fast path is the test, the original instruction, a branch past the inline path",
              all(words(r["code"])[3] == words(r["orig"])[0] for r in rows if r["size"] > 0))
        # ordering cannot be seen on one emulated thread: the inline path has a full barrier (dmb ish) after the lock is taken and
        # after it is released (stlr wzr to the lock), as an x86 locked operation is a full barrier
        def barriers(w, tmp1):
            stlr = [i for i, x in enumerate(w) if x == (0x889FFC1F | (tmp1 << 5))]
            dmb = [i for i, x in enumerate(w) if x == 0xD5033BBF]
            return len(stlr) == 1 and len(dmb) == 2 and dmb[0] < stlr[0] < dmb[1] == stlr[0] + 1
        check("the inline path: a full barrier after taking the lock and after its release",
              all(barriers(words(r["code"]), tmps[0]) for r in rows if r["size"] > 0))
        results[wow] = (lock, rows, tmps)

if unicorn is None:
    print("NOTE: Python's unicorn module is not installed; the emitted sequences were not run (pip install unicorn)")
else:
    CODE, DATA, PAGE = 0x100000, 0x400000, 0x1000

    def expect(op, size, old, val):
        mask = (1 << (8 << size)) - 1
        new = {0: val, 1: old + val, 2: old & ~val, 3: old | val, 4: old ^ val}[op]
        return new & mask

    def emulate(r, tmps, lock, offset, *, first_page=True, second_page=True, lock_held=False, stop_at=None):
        mu = unicorn.Uc(unicorn.UC_ARCH_ARM64, unicorn.UC_MODE_ARM)
        mu.ctl_set_cpu_model(A.UC_CPU_ARM64_MAX)
        code = le(r["code"]) + struct.pack("<I", 0xD4200000)    # brk #0 at the end
        mu.mem_map(CODE, 0x10000)
        mu.mem_write(CODE, code)
        if first_page:
            mu.mem_map(DATA, PAGE)
        if second_page:
            mu.mem_map(DATA + PAGE, PAGE)
        pattern = bytes((i * 37 + 11) & 0xFF for i in range(PAGE * 2))
        if first_page:
            mu.mem_write(DATA, pattern[:PAGE])
        if second_page:
            mu.mem_write(DATA + PAGE, pattern[PAGE:])
        lpage = lock & ~(PAGE - 1)
        mu.mem_map(lpage, PAGE)
        mu.mem_write(lock, struct.pack("<I", 1 if lock_held else 0))
        regs = {}
        for i in range(31):
            regs[i] = (0x1111111111111111 * ((i % 15) + 1)) ^ (i << 56)
            mu.reg_write(getattr(A, "UC_ARM64_REG_X%d" % i), regs[i])
        regs[r["m"]] = DATA + offset
        mu.reg_write(getattr(A, "UC_ARM64_REG_X%d" % r["m"]), DATA + offset)
        nzcv = 0xA0000000
        mu.reg_write(A.UC_ARM64_REG_NZCV, nzcv)
        executed = []
        mu.hook_add(unicorn.UC_HOOK_CODE, lambda uc, addr, size, user: executed.append(addr))
        lock_writes = []
        mu.hook_add(unicorn.UC_HOOK_MEM_WRITE, lambda uc, access, addr, size, value, user: lock_writes.append((addr, value)),
                    begin=lock, end=lock + 3)
        fault = None
        try:
            mu.emu_start(CODE, stop_at if stop_at is not None else CODE + len(code) - 4)
        except unicorn.UcError as e:
            fault = e
        regs_after = {i: mu.reg_read(getattr(A, "UC_ARM64_REG_X%d" % i)) for i in range(31)}
        mem = (bytes(mu.mem_read(DATA, PAGE)) if first_page else b"") + (bytes(mu.mem_read(DATA + PAGE, PAGE)) if second_page else b"")
        return dict(fault=fault, pc=mu.reg_read(A.UC_ARM64_REG_PC), regs=regs, after=regs_after, mem=mem, pattern=pattern,
                    nzcv=mu.reg_read(A.UC_ARM64_REG_NZCV), lock=struct.unpack("<I", bytes(mu.mem_read(lock, 4)))[0],
                    lock_writes=lock_writes, executed=executed, code_len=len(code))

    for wow, (lock, rows, tmps) in sorted(results.items()):
        name = "WOW64" if wow else "ARM64EC"
        bad = {k: [] for k in ("aligned", "inside", "crossing", "pages", "probe", "tries")}
        for r in rows:
            if r["size"] == 0:
                continue
            nb = 1 << r["size"]
            fast_lse = CODE + 12
            # aligned, at a block's start and ending at its last byte: the original instruction alone, the lock never touched
            for off in (0x40, 0x50 - nb):
                e = emulate(r, tmps, lock, off)
                lse_runs = [a for a in e["executed"] if a == fast_lse]
                if e["fault"] or len(lse_runs) != 1 or e["lock_writes"] or e["nzcv"] != 0xA0000000:
                    bad["aligned"].append((r["op"], r["size"], r["layout"], off, e["fault"], e["lock_writes"]))
            # misaligned inside one 16-byte block, also across an 8-byte boundary (unicorn has no LSE2, so it runs up to the
            # instruction): the fast path
            for off in (0x41, 0x48 - nb + 1, 0x50 - nb - 1):
                e = emulate(r, tmps, lock, off, stop_at=fast_lse)
                if e["fault"] or e["pc"] != fast_lse or e["lock_writes"]:
                    bad["inside"].append((r["op"], r["size"], r["layout"], off, e["fault"], hex(e["pc"])))
            # crossing a 16-byte boundary inside a page, and across two pages
            for off, key in ((0x50 - nb + 1, "crossing"), (PAGE - nb + 1, "pages")):
                e = emulate(r, tmps, lock, off)
                old = int.from_bytes(e["pattern"][off:off + nb], "little")
                val = e["regs"][r["v"]] if r["v"] != 31 else 0
                new = expect(r["op"], r["size"], old, val)
                want_mem = bytearray(e["pattern"])
                want_mem[off:off + nb] = new.to_bytes(nb, "little")
                changed = {i for i in range(31) if e["after"][i] != e["regs"][i]}
                allowed = {tmps[0], tmps[2], tmps[3], r["d"]}
                problems = []
                if e["fault"]:
                    problems.append("fault %s at +%#x" % (e["fault"], e["pc"] - CODE))
                if e["mem"] != bytes(want_mem):
                    problems.append("memory")
                if e["after"][r["d"]] != old:
                    problems.append("dst %#x != old %#x" % (e["after"][r["d"]], old))
                if not changed <= allowed:
                    problems.append("registers %s" % sorted(changed - allowed))
                if e["nzcv"] != 0xA0000000:
                    problems.append("NZCV %#x" % e["nzcv"])
                if e["lock"] != 0 or [v for _, v in e["lock_writes"]] != [1, 0]:
                    problems.append("lock %s %s" % (e["lock"], e["lock_writes"]))
                if fast_lse in e["executed"]:
                    problems.append("the original instruction ran")
                if problems:
                    bad[key].append((r["op"], r["size"], r["layout"], problems))
            # a crossing operand with its first or its last byte on a page that is not mapped: a fault at a probe, before the lock
            for first, second in ((True, False), (False, True)):
                e = emulate(r, tmps, lock, PAGE - nb + 1, first_page=first, second_page=second)
                pc_word = words(r["code"])[(e["pc"] - CODE) // 4] if CODE <= e["pc"] < CODE + len(r["code"]) else None
                if not e["fault"] or e["lock_writes"] or pc_word is None or (pc_word & 0xFFFFFC1F) != 0x383F001F:
                    bad["probe"].append((r["op"], r["size"], r["layout"], first, str(e["fault"]), pc_word and hex(pc_word)))
            # the lock held elsewhere: after the tries, the original instruction (which traps here, as on the device)
            if r["layout"] == 0 and r["op"] in (0, 1):
                e = emulate(r, tmps, lock, 0x50 - nb + 1, lock_held=True)
                pc_word = words(r["code"])[(e["pc"] - CODE) // 4] if CODE <= e["pc"] < CODE + len(r["code"]) else None
                spins = sum(1 for a in e["executed"] if a == CODE + 4 * next(i for i, w in enumerate(words(r["code"])) if (w & 0xFFE0FC00) == 0xB8A08000))
                if not e["fault"] or pc_word != words(r["orig"])[0] or e["lock"] != 1 or spins != 0x10000 or e["mem"] != e["pattern"][:len(e["mem"])]:
                    bad["tries"].append((r["op"], r["size"], str(e["fault"]), pc_word and hex(pc_word), e["lock"], spins))
        check("%s: an aligned operand runs the original instruction alone, the lock untouched, NZCV kept" % name, not bad["aligned"], bad["aligned"][:3])
        check("%s: an operand inside one 16-byte block (misaligned, across an 8-byte boundary, ending at the block's end) takes the "
              "original instruction" % name, not bad["inside"], bad["inside"][:3])
        check("%s: a crossing operand: old value zero-extended to the destination, new value in memory, nothing else written, "
              "NZCV and other registers kept, the lock taken and released, the original instruction not run" % name, not bad["crossing"], bad["crossing"][:3])
        check("%s: the same across two pages" % name, not bad["pages"], bad["pages"][:3])
        check("%s: a crossing operand with its first or last byte on an unmapped page faults at a probe, the lock untouched" % name, not bad["probe"], bad["probe"][:3])
        check("%s: with the lock held elsewhere, 65536 tries, then the original instruction (its trap), memory and lock untouched" % name,
              not bad["tries"], bad["tries"][:3])

# ---------------------------------------------------------------- 3. the wiring
apply = (root / "build/fex-patches/apply.sh").read_text()
builds = [(root / f).read_text() for f in ("build/fex-arm64ec/build.sh", "build/fex-wow64/build.sh")]
readme = (root / "build/fex-patches/README.md").read_text()
check("both FEX builds run apply.sh, which applies every build/fex-patches/*.patch in order; the README lists the patch",
      all('bash "$R/build/fex-patches/apply.sh"' in b for b in builds) and '"$R"/build/fex-patches/*.patch' in apply
      and "`" + patch_file.name + "`" in readme)
gen = (root / "build/tools/gen-config-catalog.py").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text()
check("the catalog documents the switch, on by default; the session end clears it",
      re.search(r'"env\.MADEIRA_FEX_SPLIT_LOCK": \{[^}]*"default": "1"', gen, re.S) is not None
      and 'key: "env.MADEIRA_FEX_SPLIT_LOCK"' in cat and 'unsetenv("MADEIRA_FEX_SPLIT_LOCK");' in bridge)
print("PASS: fex-split-lock" if ok else "FAILED: fex-split-lock")
sys.exit(0 if ok else 1)
