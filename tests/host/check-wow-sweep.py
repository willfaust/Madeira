#!/usr/bin/env python3
"""Production-source regression for WOW64 syscall parking; no Wine, FEX JIT or guest runs.

On a device, a desktop client's 32-bit processes kept 30 code-buffer generations
(720 MB of the 896 MB pool) alive, because a WOW64 thread blocked in a syscall has a return
address into its generation and the code-buffer sweeper never saw WOW64 threads. A thread then
died at the out-of-pool fault holding FEX's shared lock and the process hung.

Part A checks the source invariants the redirect depends on (the emitted syscall tail, the
entry stub, park/unpark placement, registration). Part B compiles the production
IosWowPark/IosWowUnpark/IosWowSyscallC against a fake sweeper and nested callbacks.
"""
from pathlib import Path
import re, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
mod = (root / "FEX/Source/Windows/WOW64/Module.cpp").read_text()
cpu = (root / "FEX/FEXCore/Source/Interface/Core/CPUBackend.cpp").read_text()
branch = (root / "FEX/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp").read_text()
opd = (root / "FEX/FEXCore/Source/Interface/Core/OpcodeDispatcher.cpp").read_text()
emit = (root / "FEX/FEXCore/Source/Interface/Core/ArchHelpers/Arm64Emitter.h").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]

# ---- Part A: invariants
syscall_op = function(branch, "DEF_OP(Syscall)")
tail = syscall_op[syscall_op.index("blr(ARMEmitter::Reg::r3)"):]
assert "FillStaticRegs" in tail and "InSyscallInfo" in tail and "PopDynamicRegs" in tail, "emitted tail refills, clears, pops"
assert "OS_GENERIC" in tail, "OS_GENERIC result is not written back"
tables = (root / "FEX/FEXCore/Source/Interface/Core/X86Tables/X86Tables.h").read_text()
base = (root / "FEX/FEXCore/Source/Interface/Core/X86Tables/BaseTables.cpp").read_text()
assert "*reinterpret_cast<uint32_t*>(Addr) = 0x2ecd2ecd;" in mod, "the WOW64 bridges are int 0x2e"
assert re.search(r'\{0xCD, 1, X86InstInfo\{"INT",\s+TYPE_INST, DEFAULT_SYSCALL_FLAGS', base), "INT uses the syscall flags"
win = tables[tables.index("#ifndef _WIN32\n  constexpr uint32_t DEFAULT_SYSCALL_FLAGS"):]
assert "#else" in win and "FLAGS_BLOCK_END" in win[win.index("#else"):win.index("#endif")], "on Windows a syscall ends its block"
intop = function(opd, "void OpDispatchBuilder::INTOp(")
assert re.search(r"SYSCALL_LITERAL = 0x2E;\s*if \(Literal == SYSCALL_LITERAL\) \{[^}]*SyscallOp\(Op, false\);", intop), "int 0x2e is a syscall on WOW64"
assert re.search(r"FLAGS_BLOCK_END\) \{\s*// RIP could have been updated.*?\n\s*NewRIP = _LoadContextGPR.*?\n\s*ExitFunction\(NewRIP\);", opd, re.S), \
    "block-ending syscalls reload RIP from the context and exit to the dispatcher"
nonec = emit[emit.index("#ifndef ARCHITECTURE_arm64ec"):emit.index("#else", emit.index("#ifndef ARCHITECTURE_arm64ec"))]
assert "TMP2 = ARMEmitter::XReg::x1;" in nonec and "ENTRY_FILL_SRA_SINGLE_INST_REG = TMP2" in emit, "single-inst flag is x1 on WOW64"
stub = function(mod, 'extern "C" __attribute__((naked)) void IosWowSyscallEntry()')
order = [s for s in ["mov x3, sp;", ".seh_nop;", "stp x29, x30, [sp, #-16]!;", "bl IosWowSyscallC;", "ldp x29, x30, [sp], #16;",
                     "cbnz x0, 1f;", "ret;", "mov sp, x0;", "mov x16, x1;", "mov x1, #0;", "br x16;"]]
pos = [stub.index(s) for s in order]
assert pos == sorted(pos), "entry stub order"
impl = function(mod, "static uint64_t HandleSyscallImpl(")
for call in ["WineUnixCall(", "Wow64SystemServiceEx("]:
    i = impl.index(call)
    before, after = impl[:i], impl[i:]
    assert before.rindex("IosWowPark(TD);") > before.rindex("Context::UnlockJITContext(TLS);"), f"park after unlock for {call}"
    assert after.index("IosWowUnpark(TD);") < after.index("Context::LockJITContext(TLS);"), f"unpark before lock for {call}"
init = function(mod, "void BTCpuThreadInit()")
assert "IosWowSweepEnabled()" in init and "Pointers.SyscallHandlerFunc = reinterpret_cast<uint64_t>(&IosWowSyscallEntry)" in init \
    and "IosSweepRegisterThreadEx(Thread, &TD->IosInSim, &TD->IosMigrated)" in init, "thread registration"
term = function(mod, "void BTCpuThreadTerm(")
assert term.index("IosSweepUnregisterThread(ThreadState)") < term.index("delete GetFrontendThreadData(ThreadState)"), "unregister before free"
sim = function(mod, 'extern "C" void BTCpuSimulateImpl(')
assert sim.index("IosWowUnpark(") < sim.index("ExecuteThread("), "simulation entry unparks"
assert "case 1:" in cpu and "*Snap[i].Migrated = 1;" in cpu and "IosSweepRegisterThreadEx(Thread, InSimPtr, nullptr);" in cpu, "sweeper flags moves"
print("PASS: syscall tail, entry stub, park/unpark placement, registration and sweeper flag invariants")

# ---- Part B: behaviour of the production parking code
td = mod[mod.index("struct FrontendThreadData {"):mod.index("class WowSyscallHandler;")]
# Since the FEX pin of #461 the parking code ends an #ifdef FEX_IOS_HOST block: leave its #endif out.
park = mod[mod.index("static bool IosWowSweepEnabled()"):mod.index("// Returns the HOST address of the 32-bit TEB")].replace("\n#endif\n", "\n")
resume = mod[mod.index("struct IosSyscallResume {"):mod.index("// Same arguments as SyscallHandler::HandleSyscall")]
code = r"""
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cassert>
#include <functional>
namespace LogMan::Msg { template <typename... T> void EFmt(const char*, T...) { std::fputs("log\n", stderr); } }
namespace FEXCore::Core {
  struct InternalThreadState { void* FrontendPtr; };
  struct JITPointers { uint64_t DispatcherLoopTopFillSRA; };
  struct CPUState { uint64_t rip; };
  struct CpuStateFrame { CPUState State; uint64_t ReturningStackLocation; uint64_t InSyscallInfo; JITPointers Pointers; };
}
namespace FEXCore::HLE {
  struct SyscallArguments {};
  struct SyscallHandler { virtual uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame*, SyscallArguments*) = 0; };
}
""" + td + r"""
static FEXCore::Core::InternalThreadState g_thread;
struct TLSStub { FEXCore::Core::InternalThreadState* ThreadState() const { return &g_thread; } };
static TLSStub GetTLS() { return {}; }
static FrontendThreadData* GetFrontendThreadData(FEXCore::Core::InternalThreadState* T) { return static_cast<FrontendThreadData*>(T->FrontendPtr); }
extern "C" uint64_t IosCodeBufferSweepGate;
uint64_t IosCodeBufferSweepGate = 0;
""" + park.replace('__asm volatile("yield");', '').replace('extern "C" void IosSweepRegisterThreadEx', 'static void Unused1').replace('extern "C" void IosSweepUnregisterThread', 'static void Unused2').replace('extern "C" uint64_t IosCodeBufferSweepGate;', '') + resume.replace("FEXCore::Core::CpuStateFrame* Frame,\n", "FEXCore::Core::CpuStateFrame* Frame,\n").replace("struct Frame_", "FEXCore::Core::CpuStateFrame") + r"""
static void Unused1(FEXCore::Core::InternalThreadState*, volatile uint8_t*, volatile uint8_t*) {}
static void Unused2(FEXCore::Core::InternalThreadState*) {}
// A fake handler: HandleSyscallImpl's park/unpark around the "blocking call", with a sweeper
// that moves the thread whenever it sees it parked, and optional nested callbacks.
struct Handler : FEXCore::HLE::SyscallHandler {
  std::function<void()> Blocking;
  uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame* F, FEXCore::HLE::SyscallArguments*) override {
    auto* TD = GetFrontendThreadData(&g_thread);
    IosWowPark(TD);
    if (Blocking) Blocking();
    IosWowUnpark(TD);
    return 0;
  }
};
static int sweeps_moved;
static void sweep(FrontendThreadData* TD) {           // IosMaybeSweepCodeBuffers, one target
  IosCodeBufferSweepGate = 1;
  if (TD->IosInSim == 0) { TD->IosMigrated = 1; sweeps_moved++; }
  IosCodeBufferSweepGate = 0;
}
int main(int argc, char** argv) {
  FrontendThreadData TD; g_thread.FrontendPtr = &TD;
  if (argc > 1) setenv("MADEIRA_WOW_SYSCALL_SWEEP", "0", 1);
  TD.IosSweepRegistered = IosWowSweepEnabled();
  FEXCore::Core::CpuStateFrame F {};
  F.Pointers.DispatcherLoopTopFillSRA = 0xD15;
  const uint64_t caller = 0x7000100000, disp = caller + 0x1a0;
  F.ReturningStackLocation = disp; F.State.rip = 0x401000;
  Handler H; FEXCore::HLE::SyscallArguments A;
  auto call = [&](uint64_t sp) { return IosWowSyscallC(&H, &F, &A, sp); };
  if (argc > 1) {
    H.Blocking = [&] { sweep(&TD); };
    auto r = call(caller);
    assert(r.NewSP == 0 && sweeps_moved == 0 && TD.IosInSim == 1);
    std::puts("off"); return 0;
  }
  // (a) blocked + moved: resume at the dispatcher, frame repaired
  H.Blocking = [&] { assert(TD.IosInSim == 0); sweep(&TD); };
  F.InSyscallInfo = 0x8000;
  auto r = call(caller);
  assert(r.NewSP == disp && r.Target == 0xD15 && F.InSyscallInfo == 0 && F.ReturningStackLocation == disp);
  assert(TD.IosInSim == 1 && TD.IosMigrated == 0 && TD.IosSyscallDepth == 0 && !TD.IosSyscallArmed);
  // (b) blocked, not moved: normal return
  H.Blocking = [&] { assert(TD.IosInSim == 0); };
  r = call(caller); assert(r.NewSP == 0 && TD.IosInSim == 1);
  // (c) a callback re-enters simulation (unpark), makes a nested syscall (never parked),
  //     returns; a move before the callback still redirects the outer syscall
  H.Blocking = [&] {
    sweep(&TD);                                   // moved while blocked
    IosWowUnpark(&TD);                            // BTCpuSimulateImpl entry
    Handler inner; inner.Blocking = [&] { assert(TD.IosInSim == 1); sweep(&TD); };
    F.ReturningStackLocation = caller - 0x3000;   // nested dispatcher entry
    auto n = IosWowSyscallC(&inner, &F, &A, caller - 0x3200);
    assert(n.NewSP == 0);                         // nested: never armed, never moved
  };
  r = call(caller); assert(r.NewSP == disp && F.ReturningStackLocation == disp);
  // (d) a stale (deeper) dispatcher SP left by a long-jumped callback: not armed
  F.ReturningStackLocation = caller - 0x3000;
  H.Blocking = [&] { assert(TD.IosInSim == 1); sweep(&TD); };
  r = call(caller); assert(r.NewSP == 0);
  F.ReturningStackLocation = disp;
  // (e) a nested call that never returns (long jump) leaves depth behind; the outer restores it
  H.Blocking = [&] { TD.IosSyscallDepth = 7; };
  r = call(caller); assert(TD.IosSyscallDepth == 0);
  H.Blocking = [&] { sweep(&TD); };
  r = call(caller); assert(r.NewSP == disp);
  std::printf("on moved=%d\n", sweeps_moved);
  return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.cpp"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["c++", "-std=c++20", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    on = subprocess.run([str(exe)], check=True, capture_output=True, text=True)
    assert "on moved=3" in on.stdout, on.stdout + on.stderr
    off = subprocess.run([str(exe), "rollback"], check=True, capture_output=True, text=True)
    assert "off" in off.stdout
    print("PASS: parked blocked syscalls resume at the dispatcher only when moved; nested, stale-stack and long-jump cases stay pinned; rollback never parks")
