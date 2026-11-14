#!/usr/bin/env python3
"""madeira-duo section-view-grow: a MEM_RESERVE view past the end of its file section
(LMDB's database map, PoE2's Shaders/Pipelines caches) is accepted by extending the
file, the server's section follows the file, and commits inside such a view succeed."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0


def check(ok, what):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        failures += 1


v = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
m = (ROOT / 'build/wineserver/mapping_ios.c').read_text(encoding='utf-8', errors='replace')

ms = v[v.index('static unsigned int virtual_map_section('):]
ms = ms[:ms.index('\n}\n')]
check('ios_section_view_grow_ok( alloc_type )' in ms
      and ms.index('ios_section_view_grow_ok(') < ms.index('return STATUS_INVALID_VIEW_SIZE;'),
      'a view past the end of the file asks section-view-grow before refusing')
check(ms.index('res = map_view( &view,') < ms.index('ios_section_view_grow( unix_handle,') < ms.index('map_file_into_view_ex( view, unix_handle'),
      'the file is extended only once the address range is reserved, and before it is mapped')
check('delete_view( view );\n        goto done;' in ms[ms.index('ios_section_view_grow( unix_handle,'):], 'a refused extension releases the view')

grow = v[v.index('static unsigned int ios_section_view_grow('):]
grow = grow[:grow.index('\n}\n')]
check('(alloc_type & MEM_RESERVE)' in v[v.index('static int ios_section_view_grow_ok('):], 'only MEM_RESERVE views')
cap = v[v.index('static ULONGLONG ios_section_view_cap(void)'):]
cap = cap[:cap.index('\n}\n')]
check('getenv( "MADEIRA_SECTION_VIEW_CAP_GB" )' in cap and 'gb = 16' in cap and 'gb > 48' in cap,
      'the view is capped (env.MADEIRA_SECTION_VIEW_CAP_GB, default 16, at most 48)')
check('size = ios_section_view_cap() - (ULONGLONG)offset.QuadPart;' in ms
      and ms.index('size = ios_section_view_cap()') < ms.index('ios_grow_to = (ULONGLONG)offset.QuadPart + size;'),
      'a request past the cap maps the capped size, and the file grows to the capped end')
check('getenv( "MADEIRA_SECTION_VIEW_GROW" )' in v, 'env.MADEIRA_SECTION_VIEW_GROW = 0 turns it off')
check(grow.index('S_ISREG( st.st_mode )') < grow.index('ftruncate(') and grow.index('st.st_size != full_size') < grow.index('ftruncate('),
      "the descriptor must be a linked regular file of the section's size before it is extended")
check('[section-grow]' in grow and 'F_GETPATH' in grow, 'each case is logged with the file path')

commit = v[v.index('else  /* commit the pages */'):]
commit = commit[:commit.index('SERVER_START_REQ')]
check('ios_section_view_grown( view ) ? STATUS_SUCCESS : STATUS_ALREADY_COMMITTED' in commit,
      'a commit inside a grown view succeeds; other file views keep STATUS_ALREADY_COMMITTED')

mv = m[m.index('DECL_HANDLER(map_view)'):]
mv = mv[:mv.index('\n}\n')]
check(mv.index('mapping->size = st.st_size;') < mv.index('req->start >= mapping->size ||'),
      "the server's section takes the file's new size before its range check")
check('!(mapping->flags & SEC_IMAGE) && mapping->fd' in mv, 'only file-backed, non-image sections follow the file')

print(f'{failures} failure(s)')
sys.exit(1 if failures else 0)
