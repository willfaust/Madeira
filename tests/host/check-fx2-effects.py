#!/usr/bin/env python3
"""The fx_2_0 effect writer in the Wine tree's vkd3d: sampler initializers,
pass assignments and the resource records d3dx9 reads them from.

An effect compiled at run time from text (D3DXCreateEffect on a .fx source)
goes through Wine's d3dx9 -> d3dcompiler -> vkd3d-shader, target fx_2_0.
Release 1.19 of vkd3d stopped on the first sampler with a state block
("Writing fx_2_0 sampler objects initializers is not implemented") and on
every pass with assignments ("Write pass assignments"), so a program showed
its "Error building shader" dialog and ran without the effect.

Structural part (always): wine/libs/vkd3d/libs/vkd3d-shader/fx.c has the
writer pieces and none of the three refusals.

Functional part: set VKD3D_COMPILER to a vkd3d-compiler built from that tree
(docs/BUILDING.md, "fx_2_0 effects") and the test compiles a small effect to
fx_2_0 and reads the binary back the way dlls/d3dx9_36/effect.c does: the
sampler's states follow its state count without gaps, Texture = <t> is an
object whose resource record names the parameter, each pass shader is an
object whose resource record carries SM3 bytecode, numeric states are INT
scalars, object ids are unique and the records end exactly at the file end.
Without the variable the functional part prints SKIP.
"""
from pathlib import Path
import os
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
fx_c = root / 'wine/libs/vkd3d/libs/vkd3d-shader/fx.c'
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print('FAIL:', what)


src = fx_c.read_text(encoding='utf-8', errors='replace')
for refusal in ('Writing fx_2_0 sampler objects initializers is not implemented',
                'Write pass assignments.',
                'Writing fx_2_0 state assignments is not implemented'):
    check(refusal not in src, 'fx.c still refuses: %s' % refusal)
for piece in ('static uint32_t write_fx_2_sampler_initializer(',
              'static void write_fx_2_resource(',
              'static uint32_t write_fx_2_object_type(',
              'static bool compile_shader(',
              'struct vkd3d_bytecode_buffer *fx_2_state_buffer;'):
    check(piece in src, 'fx.c lacks %s' % piece)
assign = src[src.index('static void write_fx_2_state_assignment('):]
assign = assign[:assign.index('\n}\n')]
for case in ('case HLSL_IR_CONSTANT:', 'case HLSL_IR_COMPILE:', 'case HLSL_IR_LOAD:'):
    check(case in assign, 'write_fx_2_state_assignment lacks %s' % case)
params = src[src.index('static void write_fx_2_parameters('):]
params = params[:params.index('\n}\n')]
check('&ctx->globals->vars' in params and 'extern_vars' not in params,
      'write_fx_2_parameters must walk the globals: compiling a pass shader rebuilds the externs list')
trailer = src[src.index('static int hlsl_fx_2_write('):]
trailer = trailer[:trailer.index('\n}\n')]
check('fx.object_record_count' in trailer and 'fx.resource_count' in trailer and 'fx.resources.data' in trailer,
      'hlsl_fx_2_write must write the object record count, the resource count and the resource records')

EFFECT = r'''
texture ColorTex;
float4 Tint = float4(1, 1, 1, 1);

sampler2D ColorSampler
{
    Texture = <ColorTex>;
    AddressU = Clamp;
    MinFilter = Linear;
    MagFilter = Point;
};

void VSMain(in float4 pos : POSITION, in float2 uv : TEXCOORD0,
            out float4 opos : POSITION, out float2 ouv : TEXCOORD0)
{
    opos = pos;
    ouv = uv;
}

float4 PSMain(in float2 uv : TEXCOORD0) : COLOR0
{
    return tex2D(ColorSampler, uv) * Tint;
}

float4 PSDark(in float2 uv : TEXCOORD0) : COLOR0
{
    return tex2D(ColorSampler, uv) * 0.5;
}

technique Blit
{
    pass P0
    {
        VertexShader = compile vs_3_0 VSMain();
        PixelShader = compile ps_3_0 PSMain();
        ZEnable = 0;
        AlphaBlendEnable = false;
        CullMode = None;
    }
    pass P1
    {
        PixelShader = compile ps_3_0 PSDark();
        VertexShader = compile vs_3_0 VSMain();
        ZWriteEnable = false;
        MaterialDiffuse = float4(1, 0.5, 0.25, 1);
        ZEnable = true;
    }
}
'''

# d3dx9shader.h
PT_INT, PT_FLOAT, PT_TEXTURE, PT_SAMPLER, PT_SAMPLERCUBE, PT_PIXELSHADER, PT_VERTEXSHADER = 2, 3, 5, 10, 14, 15, 16
PC_MATRIX_ROWS, PC_OBJECT = 2, 4
# dlls/d3dx9_36/effect.c state_table indices
OP_ZENABLE, OP_ZWRITEENABLE, OP_CULLMODE, OP_ALPHABLENDENABLE, OP_MATERIALDIFFUSE = 0, 3, 8, 13, 127
OP_VERTEXSHADER, OP_PIXELSHADER, OP_TEXTURE, OP_ADDRESSU, OP_MAGFILTER, OP_MINFILTER = 146, 147, 164, 165, 169, 170
VS_3_0, PS_3_0 = 0xfffe0300, 0xffff0300


class Reader:
    """Reads the binary like d3dx_parse_effect(): structured records in
    order, with offsets into the unstructured block that follows the header."""

    def __init__(self, data):
        self.d = data
        tag, size = struct.unpack_from('<II', data, 0)
        check(tag == 0xfeff0901, 'bad tag %#x' % tag)
        self.base = 8
        self.pos = 8 + size

    def u32(self):
        v = struct.unpack_from('<I', self.d, self.pos)[0]
        self.pos += 4
        return v

    def at(self, off):
        return struct.unpack_from('<I', self.d, self.base + off)[0]

    def name(self, off):
        n = self.at(off)
        return self.d[self.base + off + 4:self.base + off + 4 + n].rstrip(b'\0').decode() if n else ''

    def typedef(self, off):
        t, c, no, so, ec = struct.unpack_from('<5I', self.d, self.base + off)
        rows = cols = None
        if c in (0, PC_MATRIX_ROWS, 3):
            rows, cols = struct.unpack_from('<II', self.d, self.base + off + 20)
        return dict(type=t, cls=c, name=self.name(no), elems=ec, rows=rows, cols=cols)

    def state(self):
        op, index, to, vo = self.u32(), self.u32(), self.u32(), self.u32()
        td = self.typedef(to)
        value = self.at(vo)
        return dict(op=op, index=index, td=td, value=value, vo=vo)

    def data(self):
        size = self.u32()
        blob = self.d[self.pos:self.pos + size]
        self.pos += (size + 3) & ~3
        return blob


def functional(compiler):
    with tempfile.TemporaryDirectory() as tmp:
        fx = Path(tmp) / 'sample.fx'
        out = Path(tmp) / 'sample.fxo'
        fx.write_text(EFFECT)
        r = subprocess.run([compiler, '-x', 'hlsl', '-p', 'fx_2_0', '-b', 'fx', str(fx), '-o', str(out)],
                           capture_output=True, text=True)
        check(r.returncode == 0 and out.exists(), 'vkd3d-compiler failed:\n%s%s' % (r.stdout, r.stderr))
        if failures:
            return
        data = out.read_bytes()
    rd = Reader(data)
    nparams, ntech, _nshaders, nobjects = rd.u32(), rd.u32(), rd.u32(), rd.u32()
    check(nparams == 3 and ntech == 1, 'params=%d techniques=%d' % (nparams, ntech))
    ids = []
    object_states = []     # (technique, index, element, state_index, op, object id)
    params = []
    for i in range(nparams):
        to, vo, _flags, nann = rd.u32(), rd.u32(), rd.u32(), rd.u32()
        td = rd.typedef(to)
        params.append(td['name'])
        check(nann == 0, 'parameter %s has annotations' % td['name'])
        if PT_SAMPLER <= td['type'] <= PT_SAMPLERCUBE:
            # vkd3d writes sampler2D parameters as SAMPLER; d3dx9 treats the five alike.
            check(td['cls'] == PC_OBJECT, 'sampler typedef class %d' % td['cls'])
            # The state count and the records sit at the value offset, one after another.
            save = rd.pos
            rd.pos = rd.base + vo
            count = rd.u32()
            check(count == 4, 'sampler state count %d' % count)
            states = [rd.state() for _ in range(count)]
            rd.pos = save
            ops = [s['op'] for s in states]
            check(ops == [OP_TEXTURE, OP_ADDRESSU, OP_MINFILTER, OP_MAGFILTER], 'sampler state ops %r' % ops)
            tex = states[0]
            check(tex['td']['type'] == PT_TEXTURE and tex['td']['cls'] == PC_OBJECT and tex['td']['elems'] == 0,
                  'Texture state typedef %r' % tex['td'])
            ids.append(tex['value'])
            object_states.append((0xffffffff, i, 0, 0, OP_TEXTURE, tex['value']))
            for s in states[1:]:
                check(s['td']['type'] == PT_INT and s['td']['cls'] == PC_MATRIX_ROWS
                      and s['td']['rows'] == 1 and s['td']['cols'] == 1, 'sampler numeric state typedef %r' % s['td'])
            # D3DTADDRESS_CLAMP, D3DTEXF_LINEAR, D3DTEXF_POINT
            check([s['value'] for s in states[1:]] == [3, 2, 1],
                  'sampler state values %r' % [s['value'] for s in states[1:]])
        elif td['type'] == PT_TEXTURE:
            ids.append(rd.at(vo))
    check(params == ['ColorTex', 'Tint', 'ColorSampler'], 'parameters %r' % params)
    for t in range(ntech):
        no, nann, npass = rd.u32(), rd.u32(), rd.u32()
        check(rd.name(no) == 'Blit' and nann == 0 and npass == 2, 'technique %r passes=%d' % (rd.name(no), npass))
        for p in range(npass):
            pn, pann, nstates = rd.u32(), rd.u32(), rd.u32()
            check(pann == 0, 'pass %s has annotations' % rd.name(pn))
            states = [rd.state() for _ in range(nstates)]
            ops = [s['op'] for s in states]
            expected = ([OP_VERTEXSHADER, OP_PIXELSHADER, OP_ZENABLE, OP_ALPHABLENDENABLE, OP_CULLMODE]
                        if p == 0 else [OP_PIXELSHADER, OP_VERTEXSHADER, OP_ZWRITEENABLE, OP_MATERIALDIFFUSE, OP_ZENABLE])
            check(ops == expected, 'pass %d state ops %r' % (p, ops))
            for k, s in enumerate(states):
                check(s['index'] == 0, 'pass state index %d' % s['index'])
                if s['op'] in (OP_VERTEXSHADER, OP_PIXELSHADER):
                    want = PT_VERTEXSHADER if s['op'] == OP_VERTEXSHADER else PT_PIXELSHADER
                    check(s['td']['type'] == want and s['td']['cls'] == PC_OBJECT and s['td']['elems'] == 0,
                          'shader state typedef %r' % s['td'])
                    ids.append(s['value'])
                    object_states.append((t, p, 0xffffffff, k, s['op'], s['value']))
                elif s['op'] == OP_MATERIALDIFFUSE:
                    # A vector value is a column of its components, as the native compiler writes it
                    # (FLOAT, MATRIX_ROWS, 4 rows x 1 column), with every component in the value.
                    check(s['td']['type'] == PT_FLOAT and s['td']['cls'] == PC_MATRIX_ROWS
                          and s['td']['rows'] == 4 and s['td']['cols'] == 1, 'vector pass state typedef %r' % s['td'])
                    comps = struct.unpack_from('<4f', rd.d, rd.base + s['vo'])
                    check(comps == (1.0, 0.5, 0.25, 1.0), 'vector pass state value %r' % (comps,))
                else:
                    check(s['td']['type'] == PT_INT and s['td']['cls'] == PC_MATRIX_ROWS and s['td']['rows'] == 1,
                          'numeric pass state typedef %r' % s['td'])
            if p == 0:
                check([s['value'] for s in states[2:]] == [0, 0, 1], 'pass 0 values %r' % [s['value'] for s in states[2:]])
            else:
                # ZWriteEnable = false, ZEnable = true (TRUE resolves next to ZEnable's own USEW)
                check([states[2]['value'], states[4]['value']] == [0, 1],
                      'pass 1 values %r' % [states[2]['value'], states[4]['value']])
    nrecords, nresources = rd.u32(), rd.u32()
    check(nrecords == 1, 'object records %d (only the texture parameter has one)' % nrecords)
    for _ in range(nrecords):
        oid = rd.u32()
        blob = rd.data()
        check(oid in ids and not blob, 'object record id=%d size=%d' % (oid, len(blob)))
    check(nresources == len(object_states), 'resources %d, object states %d' % (nresources, len(object_states)))
    seen = set()
    for _ in range(nresources):
        tech, index, elem, sidx, usage = rd.u32(), rd.u32(), rd.u32(), rd.u32(), rd.u32()
        blob = rd.data()
        match = [s for s in object_states if s[:4] == (tech, index, elem, sidx)]
        check(len(match) == 1, 'resource (%#x, %d, %#x, %d) matches %d object states' % (tech, index, elem, sidx, len(match)))
        if not match:
            continue
        op = match[0][4]
        seen.add(match[0][:4])
        if op == OP_TEXTURE:
            check(usage == 1 and blob == b'ColorTex\0', 'Texture resource usage=%d data=%r' % (usage, blob))
        else:
            version = struct.unpack_from('<I', blob, 0)[0] if len(blob) >= 4 else 0
            want = VS_3_0 if op == OP_VERTEXSHADER else PS_3_0
            check(usage == 0 and version == want, 'shader resource usage=%d version=%#x' % (usage, version))
    check(len(seen) == len(object_states), 'every object state has its resource record')
    check(len(ids) == len(set(ids)) and all(0 < i < nobjects for i in ids),
          'object ids %r unique and below the object count %d' % (ids, nobjects))
    check(rd.pos == len(data), 'records end at %d, file is %d bytes' % (rd.pos, len(data)))


compiler = os.environ.get('VKD3D_COMPILER')
if compiler:
    functional(compiler)
else:
    print('SKIP: set VKD3D_COMPILER to a vkd3d-compiler built from wine/libs/vkd3d to compile the sample effect')

if failures:
    print('%d failure(s)' % len(failures))
    sys.exit(1)
print('OK: fx_2_0 sampler initializers, pass assignments and resource records' + (' (compiled)' if compiler else ''))
