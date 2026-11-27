"""Portable x86-64 ELF build tools for the host fixtures.

The sc-* fixtures assemble hand-written GNU-syntax x86-64 .S sources, link
them with a custom script, and extract raw sections / symbol addresses. GNU
binutils does that directly (Linux CI). On Darwin there is no GNU as/ld/objcopy,
so fall back to the repo's vendored llvm-mingw toolchain: clang's integrated
assembler with an ELF target, ld.lld, llvm-objcopy and llvm-nm. A GNU --defsym
pair becomes a .set prologue plus an .include of the real source.
"""
import re
import subprocess
from pathlib import Path

_TOOLCHAINS = Path(__file__).resolve().parents[2] / 'toolchains'


def _gnu():
    """True when 'as' is the GNU assembler (Linux CI, or binutils in PATH)."""
    try:
        out = subprocess.run(['as', '--version'], capture_output=True, text=True).stdout
        return out.splitlines()[0].startswith('GNU assembler')
    except (OSError, IndexError):
        return False


def _vendored():
    for tool in sorted(_TOOLCHAINS.glob('llvm-mingw-*/bin')):
        if all((tool / name).exists() for name in ('clang', 'ld.lld', 'llvm-objcopy', 'llvm-nm')):
            return tool
    return None


def _tool(name):
    """GNU binutils name, or the llvm-mingw equivalent under a fixed mapping."""
    if _gnu():
        return name
    tool = _vendored()
    if tool is None:
        raise RuntimeError('no x86-64 ELF toolchain: need GNU binutils or toolchains/llvm-mingw-*')
    return str(tool / {'ld': 'ld.lld', 'objcopy': 'llvm-objcopy', 'nm': 'llvm-nm'}[name])


def assemble(source, out, defsym=()):
    """as --64 [*defsym] source -o out, or clang -target x86_64-linux-gnu otherwise."""
    source, out = str(source), str(out)
    if _gnu():
        subprocess.run(['as', '--64', *defsym, source, '-o', out], check=True)
        return
    tool = _vendored()
    if tool is None:
        raise RuntimeError('no x86-64 ELF toolchain: need GNU binutils or toolchains/llvm-mingw-*')
    asm = source
    pairs = [a for a in defsym if a != '--defsym']
    if pairs:
        sets = ''.join('.set %s, %s\n' % tuple(a.split('=', 1)) for a in pairs)
        wrapper = Path(out).with_suffix('.wrap.S')
        wrapper.write_text(sets + '.include "%s"\n' % Path(source).resolve())
        asm = str(wrapper)
    subprocess.run([str(tool / 'clang'), '--target=x86_64-linux-gnu', '-x', 'assembler',
                    '-c', asm, '-o', out], check=True)
    _strip_empty_sections(tool, out)


def _strip_empty_sections(tool, obj):
    """clang's assembler emits the default .text even for sources that never use
    it; the empty input then forces alignment padding on neighbouring inputs in
    the link (GNU as creates no such section). Drop every zero-size PROGBITS
    section so both toolchains see identical inputs."""
    listing = subprocess.run([str(tool / 'llvm-readobj'), '--sections', obj],
                            capture_output=True, text=True, check=True).stdout
    for block in listing.split('Name: ')[1:]:
        name = re.sub(r' \(\d+\)\s*$', '', block.splitlines()[0]).strip()
        kind = re.search(r'Type: (\S+)', block)
        size = re.search(r'Size: (\d+)', block)
        if name and kind and size and kind[1] == 'SHT_PROGBITS' and int(size[1]) == 0:
            subprocess.run([str(tool / 'llvm-objcopy'), '--remove-section=' + name, obj], check=True)


def link(script, objects, out):
    """ld -T script objects -o out."""
    subprocess.run([_tool('ld'), '-T', str(script), *(str(o) for o in objects), '-o', str(out)], check=True)


def objcopy_binary(elf, section, out):
    """objcopy -O binary --only-section=.section elf out."""
    subprocess.run([_tool('objcopy'), '-O', 'binary', '--only-section=.' + section,
                    str(elf), str(out)], check=True)


def nm(elf):
    """nm(1) output text for an ELF."""
    return subprocess.check_output([_tool('nm'), str(elf)], text=True)
