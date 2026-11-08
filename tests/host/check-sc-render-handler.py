#!/usr/bin/env python3
"""[sc-rph]: the browser CefApp hands out the renderer app's handler; no Wine runs.

Under --single-process Chromium asks the browser CefApp for the renderer's
CefRenderProcessHandler, and Social Club's browser app returns NULL, so the page
bridge never ran (launcher log 2026-10-04 12:56: the launcher's pages loaded,
nobody opened the per-page IPC channels, SC_INIT_ERR_WEBSITE_FAILED_LOAD after
75 s). build/ntdll-unix/virtual_ios.c installs a small thunk in the helper's own
image at map time and points the browser app's GetRenderProcessHandler slot at it.

This checks the patch structurally for every analysed helper build
(ios_sch_builds), without a Wine run and without reproducing the helper's own
code (the owner's SocialClubHelper.exe is never committed):
  - the call site sits after relocation and before the section protections and
    the eager JIT-pool copy, so the copy of .text carries the thunk;
  - each build's thunk is tests/host/sc-render-handler.S assembled against that
    build's RVAs, and a self-consistent position-independent x64 blob: its
    rip-relative rel32 displacements land exactly on the cache slot and the
    three helper routines it names (operator new, the renderer-app constructor
    and the handler getter), each the start of a guarded digest window; its
    short branches stay inside the blob; it ends in ret;
  - ios_sch_mismatch guards every byte it relies on: it selects the build by its
    TimeDateStamp and SizeOfImage, then requires that build's .text/.data
    layout, code-byte digests, the four CefApp vtable slots in the view or
    preferred base, and zero (or int3) destinations. The additional
    renderer-loop adapter and WebKit callback are executed by
    check-sc-render-loop.py;
  - every hook overwrites only bytes inside a guarded digest window;
  - the guard and the writes are gated by MADEIRA_SC_RENDER_HANDLER and
    MADEIRA_SC_CEF and by the image being SocialClubHelper.exe.
Needs python3 and binutils (as, ld, objcopy).
"""
from pathlib import Path
import re
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


def define(name):
    m = re.search(r'#define %s\s+(0x[0-9a-fA-F]+u?|[0-9]+)' % name, native)
    t = m.group(1).rstrip('uU')
    return int(t, 16) if t.startswith('0x') else int(t)


def array_bytes(name):
    start = native.index('static const unsigned char ' + name + '[')
    body = native[start:native.index('};', start) + 2]
    return bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', body[body.index('{'):]))


def table(name):
    start = native.index(' ' + name + '[] =')
    return native[start:native.index('\n};', start)]


def value(token):
    return define(token) if token.startswith('IOS') else int(token, 16)


# --- call site ----------------------------------------------------------------
mapper = function(native, 'static NTSTATUS map_image_into_view(')
call = mapper.index('ios_sc_render_handler_patch( ptr, total_size, nt, sec, nt_name );')
assert mapper.index('rel = process_relocation_block( ptr + rel->VirtualAddress, rel, delta );') < call, \
    'the patch runs after relocation'
assert call < mapper.index('mprotect_exec(sec_addr, sec_size, prot);'), 'before the eager JIT-pool copy'
# the per-section protection pass that first marks exec pages comes after the call too
assert call < mapper.index('set_vprot( view, ptr + sec[i].VirtualAddress, size, vprot )'), \
    'before the section protections'

SLOT_B = define('IOS_SCH_SLOT_BROWSER')
SLOT_R = define('IOS_SCH_SLOT_RENDERER')
assert (SLOT_B, SLOT_R) == (3, 4)

# Each build's thunk callees beyond ios_sch_builds: operator new and the
# renderer app's constructor (both guarded as digest windows).
BUILDS = [
    dict(name='first build', prefix='IOS_SCH_', suffix='', text_vs=0x17f34c, text_raw=0x17f400,
         data_vs=0x43bc, new=0x13e708, ctor=0x69a0),
    dict(name='2.4.0.296', prefix='IOS_SCH296_', suffix='296', text_vs=define('IOS_SCH296_TEXT_VS'),
         text_raw=define('IOS_SCH296_TEXT_RAW'), data_vs=define('IOS_SCH296_DATA_VS'), new=0x1622b8, ctor=0x73c0),
    dict(name='2.4.0.302', prefix='IOS_SCH302_', suffix='302', text_vs=define('IOS_SCH302_TEXT_VS'),
         text_raw=define('IOS_SCH302_TEXT_RAW'), data_vs=define('IOS_SCH302_DATA_VS'), new=0x162928, ctor=0x73c0),
]
builds = re.search(r'ios_sch_builds\[\] =\n\{(.*?)\n\};', native, re.S)[1]
assert re.findall(r'\n    \{ (IOS_SCH\w*?)STAMP,', builds) == [b['prefix'] for b in BUILDS], \
    'every analysed build is checked, in table order'

with tempfile.TemporaryDirectory(prefix='madeira-sc-rph-') as name:
    folder = Path(name)
    for build in BUILDS:
        P, s = build['prefix'], build['suffix']
        d = lambda macro: define(P + macro)
        THUNK, CACHE, GET = d('THUNK'), d('CACHE'), d('GET_HANDLER')
        NEW, CTOR = build['new'], build['ctor']
        DATA = define('IOS_SCH_DATA') if not s else d('DATA')

        # --- the thunk blob: assembled from source, then decoded ---------------
        thunk = array_bytes('ios_sch%s_thunk' % s)
        assert len(thunk) == 112, len(thunk)
        (folder / 'link.ld').write_text(
            'SECTIONS { .text 0x%x : { *(.text) } }\n' % THUNK +
            'helper_new = %d;\nrenderer_app_ctor = %d;\nget_handler = %d;\ncache = %d;\n' % (NEW, CTOR, GET, CACHE))
        subprocess.run(['as', '--64', str(root / 'tests/host/sc-render-handler.S'), '-o', str(folder / 'a.o')],
                       check=True)
        subprocess.run(['ld', '-T', str(folder / 'link.ld'), str(folder / 'a.o'), '-o', str(folder / 'a.elf')],
                       check=True)
        subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text', str(folder / 'a.elf'),
                        str(folder / 'a.bin')], check=True)
        assert (folder / 'a.bin').read_bytes() == thunk, build['name']
        assert 0xc3 in thunk, 'the thunk returns'

        # Every `e8 <rel32>` (call) and `48 8b 05 / 48 89 05 <rel32>` (cache
        # load/store): resolve the target from the instruction address.
        targets = {}
        i = 0
        while i < len(thunk) - 4:
            if thunk[i] == 0xe8:                              # call rel32
                disp = struct.unpack_from('<i', thunk, i + 1)[0]
                targets.setdefault('call', []).append((THUNK + i + 5 + disp))
                i += 5
                continue
            if thunk[i:i + 3] in (b'\x48\x8b\x05', b'\x48\x89\x05'):   # mov rax,[rip+x] / mov [rip+x],rax
                disp = struct.unpack_from('<i', thunk, i + 3)[0]
                targets.setdefault('cache', []).append((THUNK + i + 7 + disp))
                i += 7
                continue
            i += 1
        assert sorted(set(targets['call'])) == sorted({NEW, CTOR, GET}), [hex(x) for x in targets['call']]
        assert set(targets['cache']) == {CACHE}, [hex(x) for x in targets['cache']]
        # short branches (0x74/0x75/0xeb rel8) stay inside the blob
        i = 0
        while i < len(thunk) - 1:
            if thunk[i] in (0x74, 0x75, 0xeb):
                dest = i + 2 + struct.unpack_from('<b', thunk, i + 1)[0]
                assert 0 <= dest < len(thunk), (hex(THUNK + i), dest)
            i += 1

        # --- guarded windows, destinations and hooks ---------------------------
        code = [(value(m[1]), int(m[2], 16)) for m in
                re.finditer(r'\{ (IOS_SCH\w+|0x[\da-f]+), (0x[\da-f]+),', table('ios_sch%s_code' % s))]
        for target in (NEW, CTOR, GET, d('GET_NULL'), d('WEBKIT')):
            assert any(rva == target for rva, _ in code), (build['name'], hex(target), 'guarded window start')
        blobs = [(value(m[1]), m[2], int(m[3], 16), int(m[4])) for m in re.finditer(
            r'\{ (IOS_SCH\w+), (ios_sch\w+), sizeof\(\2\),\s*(0|0xcc), ([01]),', table('ios_sch%s_blob' % s))]
        assert (THUNK, 'ios_sch%s_thunk' % s, 0, 0) in blobs, 'the thunk lands only on zero bytes'
        zeros = [(value(m[1]), int(m[2])) for m in
                 re.finditer(r'\{ (IOS_SCH\w+), (\d+),', table('ios_sch%s_zero' % s))]
        assert (CACHE, 8) in zeros, 'the cache slot starts out zero'
        text_end = (0x1000 + build['text_vs'] + 0xfff) & ~0xfff
        # Past VirtualSize, inside .text's last page. 2.4.0.296's raw data runs
        # past its VirtualSize, so its tail is zeros from the file; the first
        # build's lies past its raw data. Either way ios_sch_mismatch checks it.
        assert 0x1000 + build['text_vs'] <= THUNK and THUNK + len(thunk) <= text_end, \
            'thunk past .text VirtualSize, inside its last page'
        assert DATA + build['data_vs'] <= CACHE and CACHE + 8 <= (DATA + build['data_vs'] + 0xfff) & ~0xfff, \
            'cache in .data page slack'
        hooks = [(value(m[1]), int(m[2])) for m in
                 re.finditer(r'\{ (IOS_SCH\w+|0x[\da-f]+), IOS_SCH\w+, (\d), 0xe[89], [01] \}',
                             table('ios_sch%s_hook' % s))]
        assert hooks, build['name']
        for site, span in hooks:
            assert 5 <= span and any(rva <= site and site + span <= rva + n for rva, n in code), \
                (build['name'], hex(site), 'hook overwrites only guarded bytes')
        print('PASS: %s: the thunk is sc-render-handler.S at 0x%x; its rel32s hit the cache, new, ctor and getter; '
              '%d hooks stay inside guarded windows' % (build['name'], THUNK, len(hooks)))

# --- the guard and the writes -------------------------------------------------
guard = function(native, 'static const char *ios_sch_mismatch(')
for need in ('TimeDateStamp == ios_sch_builds[k].stamp', 'SizeOfImage == ios_sch_builds[k].size',
             'total_size < build->size', 'IMAGE_FILE_MACHINE_AMD64', 'VirtualAddress == IOS_SCH_TEXT',
             'VirtualAddress == build->data', 'build->code[k].sha256', 'IOS_SCH_SLOT_BROWSER',
             'IOS_SCH_SLOT_RENDERER', 'build->get_handler', 'build->get_null', 'build->webkit',
             'build->blob[k].fill', 'build->zero[k].len'):
    assert need in guard, need
# the vtable base is read from a slot (the helper is mapped high but runs at its
# preferred base through the sub-floor when its directory is not applied), and
# accepted only as the view or the preferred base.
assert '*vtbase = vb[IOS_SCH_SLOT_BROWSER] - build->get_handler;' in guard, 'derives the vtable base from a slot'
assert "!= IOS_SCH_IMAGE_BASE" in guard and '*vtbase != b' in guard, 'base is the view or the preferred base'

patch = function(native, 'static void ios_sc_render_handler_patch(')
assert 'MADEIRA_SC_RENDER_HANDLER' in patch and 'ios_sc_cef_enabled()' in patch
assert 'MADEIRA_SC_IPC_SPLIT' in patch
assert 'ios_sc_path_is_helper(' in patch, 'only SocialClubHelper.exe'
assert patch.index('if ((why = ios_sch_mismatch(') < patch.index('memcpy( base + build->blob[k].rva'), \
    'the guard runs before any write'
after = patch[patch.index('if ((why = ios_sch_mismatch('):]
assert after.index('return;') < after.index('memcpy('), 'a mismatch returns before writing'
assert '((ULONG64 *)(base + build->vt_browser))[IOS_SCH_SLOT_RENDERER] = vtbase + build->thunk;' \
    in patch, 'points the browser app slot 4 at the thunk, in the vtables\' own base'
# The CefApp change is still only browser slot 4. The separate render-process
# handler vtable's WebKit callback now initializes and pumps the renderer loop.
assert 'vt_renderer' not in patch and 'SLOT_BROWSER]' not in patch, \
    'CefApp browser slot 3 and the renderer app vtable are unchanged'
assert '((ULONG64 *)(base + build->vt_rph))[0] = vtbase + build->loop_init;' in patch
print('PASS: guarded CefApp slot 4 change and render-process-handler WebKit callback are wired')

print('PASS: [sc-rph] renderer-process-handler patch is wired, guarded and self-consistent')
