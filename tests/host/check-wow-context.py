#!/usr/bin/env python3
"""WoW64 thread contexts on the server side (build/wineserver/mach_ios.c); no Wine runs.

Checks that the I386_CONTEXT offsets used to read and write a WoW64 thread's CPU area match the
Windows layout (compiled against a struct written from winnt.h's field order), that the capture
and the resume-time apply are reached only for i386 processes, that the apply re-validates the
syscall frame and its fingerprint while the target is halted and never overwrites x18, and that
the 64-bit capture path is still the upstream ChpeV2 one.
"""
from pathlib import Path
import re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/wineserver/mach_ios.c").read_text()

def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]

offs = dict(re.findall(r"#define (IOS_X86_\w+)\s+(0x[0-9a-f]+)\b", src))
fields = ["FLAGS", "DR0", "FLOAT", "CR0NPX", "SEGGS", "SEGFS", "SEGES", "SEGDS", "EDI", "ESI", "EBX", "EDX",
          "ECX", "EAX", "EBP", "EIP", "SEGCS", "EFLAGS", "ESP", "SEGSS", "EXT", "CTXLEN"]
harness = r"""
#include <stddef.h>
#include <stdint.h>
typedef uint32_t DWORD; typedef uint8_t BYTE;
typedef struct { DWORD ControlWord, StatusWord, TagWord, ErrorOffset, ErrorSelector, DataOffset, DataSelector;
                 BYTE RegisterArea[80]; DWORD Cr0NpxState; } FLOATING_SAVE_AREA;
typedef struct { DWORD ContextFlags, Dr0, Dr1, Dr2, Dr3, Dr6, Dr7; FLOATING_SAVE_AREA FloatSave;
                 DWORD SegGs, SegFs, SegEs, SegDs, Edi, Esi, Ebx, Edx, Ecx, Eax, Ebp, Eip, SegCs, EFlags, Esp, SegSs;
                 BYTE ExtendedRegisters[512]; } I386_CONTEXT;
"""
names = {"FLAGS": "ContextFlags", "DR0": "Dr0", "FLOAT": "FloatSave", "CR0NPX": "FloatSave.Cr0NpxState",
         "SEGGS": "SegGs", "SEGFS": "SegFs", "SEGES": "SegEs", "SEGDS": "SegDs", "EDI": "Edi", "ESI": "Esi",
         "EBX": "Ebx", "EDX": "Edx", "ECX": "Ecx", "EAX": "Eax", "EBP": "Ebp", "EIP": "Eip", "SEGCS": "SegCs",
         "EFLAGS": "EFlags", "ESP": "Esp", "SEGSS": "SegSs", "EXT": "ExtendedRegisters"}
for f in fields:
    v = offs["IOS_X86_" + f]
    if f == "CTXLEN":
        harness += f"_Static_assert(sizeof(I386_CONTEXT) == {v}, \"{f}\");\n"
    else:
        harness += f"_Static_assert(offsetof(I386_CONTEXT, {names[f]}) == {v}, \"{f}\");\n"
harness += "int main(void) { return 0; }\n"
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "layout.c"; c.write_text(harness)
    subprocess.run(["cc", "-std=gnu11", "-Wall", str(c), "-o", str(Path(t) / "layout")], check=True)
print("PASS: I386_CONTEXT offsets match the winnt.h layout")

fill = function(src, "int ios_fill_thread_context(")
assert "if (have_native && ios_process_is_wow64( thread->process ))\n        ios_wow_capture( thread, arm.__sp, wow );\n" \
       "    /* --- guest x86-64 context from TEB->ChpeV2CpuAreaInfo->ContextAmd64 --- */\n    else if (wow)" in fill
apply_ = function(src, "int ios_apply_resume_context(")
assert apply_.index("if (!ios_process_is_wow64( thread->process )) return 0;") < apply_.index("thread_suspend( port )")
g = apply_.index("thread_get_state(")
chk = apply_.index("ios_wow_frame_seq( frame ) != thread->ios_ctx_seq")
assert apply_.index("thread_suspend( port )") < g < chk < apply_.index("mach_vm_write(")
assert "for (i = 0; i < 18; i++)" in apply_
assert "for (i = 19; i < 29; i++)" in apply_
assert "arm64_regs.x0[i]" in apply_ and "arm64_regs.x19[i - 19]" in apply_
assert "thread_resume( port );" in apply_[apply_.index("done:"):]
assert "fprintf" not in apply_ and "malloc" not in apply_, "nothing that locks stdio or allocates while the target is halted"
print("PASS: i386-only capture and apply; frame and fingerprint re-checked while halted; x18 kept; no stdio while halted")
