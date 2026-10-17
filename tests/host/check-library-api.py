#!/usr/bin/env python3
"""Library front end: the renderer detection behind the library's API badge.

Compiles the production LibraryModel.apiNames and the metadata scanner's
dynamicAPIs (app/Madeira/Library.swift) into a small Swift program and checks
them on synthetic executables: ASCII and UTF-16 DLL names, case folding,
terminated names only, a tail lookup in a large file and the read budget.
Also checks LibraryRendererBadge.compact. Run from the repository root; needs
`swift` on PATH.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
s = (root / 'app/Madeira/Library.swift').read_text()


def function(name, start=0):
    p = s.index('func ' + name + '(', start)
    a = s.index('{', p)
    n = 1
    b = a + 1
    while n:
        n += (s[b] == '{') - (s[b] == '}')
        b += 1
    return s[p:b]


def type_body(name):
    p = s.index(name + ' {')
    a = s.index('{', p)
    n = 1
    b = a + 1
    while n:
        n += (s[b] == '{') - (s[b] == '}')
        b += 1
    return s[p:b]


source = 'import Foundation\nstruct LibraryModel { static ' + function('apiNames') + '}\n'
source += 'struct Scanner { ' + function('dynamicAPIs') + '}\n'
source += type_body('enum LibraryRendererBadge') + '\n'
source += r'''
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
func scan(_ bytes: Data, budget: Int = 32 * 1024 * 1024) throws -> (Set<String>, Int) {
 let url = folder.appendingPathComponent("fixture.exe")
 try bytes.write(to: url)
 var left = budget
 return (Scanner().dynamicAPIs(url, budget: &left), left)
}
assert(try! scan(Data("MZpayload D3D9.DLL\0".utf8)).0 == ["D3D9"])
assert(try! scan(Data("MZ d3d11.dll.backup\0".utf8)).0.isEmpty)
assert(try! scan(Data("not a PE d3d9.dll\0".utf8)).0.isEmpty)
let wide = Data("D3D11.DLL\0".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
assert(try! scan(Data([0x4d,0x5a]) + wide).0 == ["D3D11"])
var large = Data(repeating: 0, count: 10 * 1024 * 1024)
large[0] = 0x4d; large[1] = 0x5a
large.append(Data("OPENGL32.DLL\0".utf8))
let tail = try! scan(large)
assert(tail.0 == ["OpenGL"] && tail.1 == 24 * 1024 * 1024)
assert(try! scan(large, budget: 2).0.isEmpty)
assert(try! scan(large, budget: 0).1 == 0)
assert(LibraryRendererBadge.compact("D3D9") == "D3D9")
assert(LibraryRendererBadge.compact("D3D10/D3D9") == nil)
assert(LibraryRendererBadge.compact("D3D11 / DirectDraw") == nil)
assert(LibraryRendererBadge.compact("Wine desktop") == "Wine desktop")
assert(LibraryRendererBadge.compact(nil) == nil)
assert(LibraryRendererBadge.display("D3D12") == "DX12" && LibraryRendererBadge.display("D3D8") == "DX8")
assert(LibraryRendererBadge.display("DirectDraw") == "DDraw" && LibraryRendererBadge.display("Vulkan") == "Vulkan")
assert(LibraryRendererBadge.display("OpenGL") == "OpenGL" && LibraryRendererBadge.display("Wine desktop") == "Wine desktop")
print("PASS: dynamic renderer detection, ASCII/UTF16/case folding, terminated names, tail lookup, read budget and the API badge")
'''
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / 'library-api.swift'
    p.write_text(source)
    subprocess.run(['swift', str(p)], check=True)
