#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Three opt-in D3D12 methods that stay the old stubs unless their config key is 1
(madeira-d3d12/src/pe/madeira_d3d12.c), and upstream's pipeline library (ml1301, always on), which
replaced the opt-in d3d12-pipeline-library stub:
  d3d12-pso-cached-blob   ID3D12PipelineState::GetCachedBlob answers a 16-byte blob
  write-buffer-immediate  WriteBufferImmediate values are written in list order by a 4-byte copy
  query-timestamps        resolved timestamps and the GPU calibration value follow the CPU's monotonic clock

Static anchors only: each key is read once through mad_cfg_int_pe with default 0, the off branch is the stub it
replaced, the method is installed in its vtable, the key branch that changes behaviour, and the log line.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

# d3d12-pso-cached-blob
check('v = mad_cfg_int_pe("d3d12-pso-cached-blob", 0) ? 1 : 0;' in body('static int mad_psoblob_on(void)'),
      'pso-cached-blob: read once, default 0')
blob = body('static HRESULT STDMETHODCALLTYPE pso_GetCachedBlob(')
check('if (!mad_psoblob_on()) return stub_ID3D12PipelineState_GetCachedBlob(This, blob);' in blob
      and 'return mad_make_blob(data, MAD_PSOBLOB_SIZE, (ID3D10Blob **)blob);' in blob,
      'pso-cached-blob: off is the stub; on hands back a blob')
check(re.search(r'#define MAD_PSOBLOB_SIZE 16\b', src) is not None and 'g_pso_vtbl.GetCachedBlob = pso_GetCachedBlob;' in src,
      'pso-cached-blob: 16 bytes, installed in the pipeline-state vtable')

# The pipeline library: upstream's always-empty library (ml1301) replaced the opt-in
# d3d12-pipeline-library stub; there is no switch any more.
check('mad_piplib_on' not in src and 'mad_cfg_int_pe("d3d12-pipeline-library"' not in src,
      'pipeline-library: no opt-in switch is read (the ml1301 library is always there)')
lib = body('static HRESULT STDMETHODCALLTYPE device_CreatePipelineLibrary(')
check('memcmp(blob, g_plib_header, sizeof g_plib_header)' in lib and 'return D3D12_ERROR_DRIVER_VERSION_MISMATCH;' in lib,
      'pipeline-library: a blob that is not its own is DRIVER_VERSION_MISMATCH')
check('if (!out) return S_FALSE;' in lib, 'pipeline-library: a NULL out pointer is the capability test (S_FALSE)')
check('return E_INVALIDARG;' in body('static HRESULT STDMETHODCALLTYPE plib_LoadGraphicsPipeline(')
      and 'return (name && pso) ? S_OK : E_INVALIDARG;' in body('static HRESULT STDMETHODCALLTYPE plib_StorePipeline('),
      'pipeline-library: loads answer not-found, stores are accepted and forgotten')
check('g_device_vtbl.CreatePipelineLibrary = (void *)device_CreatePipelineLibrary;' in src,
      'pipeline-library: installed in the device vtable')

# write-buffer-immediate
wbi = body('static void STDMETHODCALLTYPE list_WriteBufferImmediate(')
check('static int g_wbi_on = -1;' in src and 'g_wbi_on = mad_cfg_int_pe("write-buffer-immediate", 0) ? 1 : 0;' in wbi,
      'write-buffer-immediate: read once, default 0')
check('if (!g_wbi_on) { madeira_d3d12_note_unimplemented("ID3D12GraphicsCommandList7", "WriteBufferImmediate"); return; }' in wbi,
      'write-buffer-immediate: off is the stub (nothing recorded)')
check('(params[i].Dest & 3) || off + 4 > r->size' in wbi and 'c = mad_list_push(l, MC_WBI);' in wbi,
      'write-buffer-immediate: an aligned 4-byte value inside a live buffer is recorded in list order')
check('case MC_WBI: {' in src and 'g_list_vtbl.WriteBufferImmediate    = (void *)list_WriteBufferImmediate;' in src,
      'write-buffer-immediate: executed by the batch, installed in the list vtable')

# query-timestamps
check('g_qts_on = mad_cfg_int_pe("query-timestamps", 0) ? 1 : 0;' in body('static int mad_qts_on(void)'),
      'query-timestamps: read once, default 0')
res = body('static void STDMETHODCALLTYPE list_ResolveQueryData(')
check('if (type == D3D12_QUERY_TYPE_TIMESTAMP && mad_qts_on()) {' in res and 'UINT64 v = now + i;' in res,
      'query-timestamps: on, resolved timestamps are the clock plus the query index (non-zero, increasing)')
check('if (gpu) *gpu = mad_qts_on() ? mad_qts_now_ns() : 0;' in body('static HRESULT STDMETHODCALLTYPE queue_GetClockCalibration('),
      'query-timestamps: GetClockCalibration reports the same clock on, zero off')

for key in ('d3d12-pso-cached-blob', 'write-buffer-immediate', 'query-timestamps'):
    check(f'"[madeira-d3d12] {key} = 1 (opt-in)' in src or f'd3d12_log("[madeira-d3d12] {key} = 1 (opt-in):' in src,
          f'{key}: logged once when on')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('d3d12-pso-cached-blob', 'write-buffer-immediate', 'query-timestamps'):
        check(f'key: "{key}"' in text, f'the config catalog documents {key}')

print(f'check-d3d12-optin-stubs: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
