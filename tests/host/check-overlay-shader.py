#!/usr/bin/env python3
"""madeira-duo overlay-shader: the performance overlay's MISS/s and PSO Q cells.

madeira-d3d12 keeps four counts after the fps-gov fields of the counter block it already
publishes with MadeiraCtl op 5 (struct mad_xp); winemetal reads them at byte 184 in
madeira_shader_overlay_stats, beside its own count of pso-archive misses, and the overlay
calls that once a tick while the "Shader misses" field is shown. Static anchors, plus the
layout: the PE's fields before the tail add up to 184 bytes, server_ios.c's mirror of
them does too, and winemetal's copy of the tail has the PE's field order.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0


def check(cond, what):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures += 1


def read(rel):
    return (ROOT / rel).read_text(encoding='utf-8', errors='replace')


pe = read('madeira-d3d12/src/pe/madeira_d3d12.c')
srv = read('build/ntdll-unix/server_ios.c')
lib = read('app/Madeira/Library.swift')
bridge = read('app/Madeira/Madeira-Bridging-Header.h')

# --- the PE block ------------------------------------------------------------------
xp = pe[pe.index('static struct mad_xp {'):pe.index('} g_xp = {')]
head, tail = xp.split('struct mad_xp_shader {')
head = re.sub(r'/\*.*?\*/', '', head, flags=re.S)
names = []
for decl in re.findall(r'LONG64\s+([^;]+);', head):
    names += [n.strip() for n in decl.split(',')]
check(len(names) * 8 == 184 and names[-3:] == ['fps_cap', 't_cap', 'n_cap'],
      f'struct mad_xp has 23 LONG64 fields (184 bytes) before the overlay tail ({len(names)} found)')
check('_Static_assert(offsetof(struct mad_xp, shader) == 184,' in pe, 'the PE build asserts the tail sits at byte 184')
tail_fields = re.findall(r'LONG64 (\w+);', tail)
check(tail_fields == ['magic', 'flags', 'sc_miss', 'pa_wait', 'pcb_wait'], f'the tail fields, in order: {tail_fields}')
check('} g_xp = { .shader = { .magic = 0x31304448534d4d4dLL } };' in pe, 'the tail carries its magic from the start')

m = re.search(r'struct ios_xp_pe \{ int64_t ([^;]+);', srv)
pe_fields = [n.strip() for n in m.group(1).split(',')] if m else []
m = re.search(r'struct ios_xp_pe_cap \{ int64_t ([^;]+);', srv)
cap_fields = [n.strip() for n in m.group(1).split(',')] if m else []
check((len(pe_fields) + len(cap_fields)) * 8 == 184 and pe_fields + cap_fields == names,
      "server_ios.c's ios_xp_pe + ios_xp_pe_cap mirror the same 184 bytes")

# --- where the PE counts --------------------------------------------------------------
check(pe.count('InterlockedIncrement64(&g_xp.shader.sc_miss)') == 3 and pe.count('mad_ovl_conv(a);') == 2,
      'shader misses: convert_full (stored, refused) and the plain/cache-off paths through mad_ovl_conv')
ovl = pe[pe.index('static void mad_ovl_conv('):pe.index('/* madeira-duo: the res3 log')]
check('a->out_buf && a->ret_len <= a->out_cap' in ovl and 'a->ret_status != MADEIRA_IR_BUFFER_TOO_SMALL' in ovl,
      'a sizing call is not counted; a fill call or a refusal is')
check(pe.count('InterlockedIncrement64(&g_xp.shader.pa_wait);') == 1 and pe.count('InterlockedIncrement64(&g_xp.shader.pcb_wait);') == 2,
      'pso-async queue +1 at its one enqueue; the create-time queue at its two (graphics, compute)')
worker = pe[pe.index('static DWORD WINAPI mad_pa_worker(void *arg) {'):pe.index('static int mad_pa_start(void) {')]
check('InterlockedDecrement64(low ? &g_xp.shader.pcb_wait : &g_xp.shader.pa_wait);' in worker,
      'the builder takes it off once the pipeline is built (or failed)')
check('InterlockedOr64(&g_xp.shader.flags, 1);' in pe and 'InterlockedOr64(&g_xp.shader.flags, 2);' in pe,
      'flags: shader cache on, pso-async on')

# --- winemetal ------------------------------------------------------------------------
wm_path = ROOT / 'dxmt/src/winemetal/unix/winemetal_unix.c'
if wm_path.exists():
    wm = wm_path.read_text(encoding='utf-8', errors='replace')
    check('#define MADEIRA_XP_SHADER_AT 184' in wm
          and 'struct madeira_xp_shader { int64_t magic, flags, sc_miss, pa_wait, pcb_wait; };' in wm
          and 'x.magic == 0x31304448534d4d4dLL' in wm and 'vm_read_overwrite(mach_task_self(), (vm_address_t)(block + MADEIRA_XP_SHADER_AT)' in wm,
          "winemetal reads the PE's tail at byte 184 (a fault-free read), in the PE's field order, behind its magic")
    check('len >= MADEIRA_XP_SHADER_AT + sizeof(struct madeira_xp_shader)' in wm,
          'an older madeira-d3d12 (shorter block) gives no d3d12 figures')
    check(wm.count('    madeira_ovl_note_miss();   /* madeira-duo overlay-shader */') == 3,
          'archive misses counted in the compute, render and render+VD creates')
    warm = wm[wm.index('static uint32_t madeira_pso_warm_submit('):]
    check('madeira_pso_warm_self = 1;' in warm and 'madeira_pso_warm_self = 0;' in warm,
          "pso-warm's own compiles are left out")
else:
    print('SKIP: dxmt submodule not checked out here')

# --- the overlay ----------------------------------------------------------------------
check('void madeira_shader_overlay_stats(unsigned long long *shader_misses, unsigned long long *pipeline_misses,' in bridge,
      'the bridging header declares it for Swift')
check('"GPU", "Shader misses", "RAM"' in lib, 'the overlay settings offer the Shader misses field (off unless picked)')
check('madeira_shader_overlay_stats(&shaders, &pipelines, &queue, &background, &flags)' in lib
      and lib.count('if model.overlayFields.contains("Shader misses") {') == 3,
      'sampled only while the field is shown; cells and the spoken summary follow the same switch')
check('Cell(id: "miss", label: "MISS/s"' in lib and 'Cell(id: "psoq", label: "PSO Q"' in lib, 'two cells: MISS/s and PSO Q')

print(f'{failures} failure(s)')
sys.exit(1 if failures else 0)
