#!/usr/bin/env python3
"""Write app/MadeiraSim.xcodeproj: a copy of Madeira.xcodeproj for the iOS Simulator.

Archive references point at the relabelled copies in build/sim/lib (tools/sim/relabel-archives.py),
and MetalFX, which the simulator SDK lacks, is dropped from the link phase.
"""
import os, re, shutil, sys

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = os.path.join(root, "app", "Madeira.xcodeproj")
dst = os.path.join(root, "app", "MadeiraSim.xcodeproj")
lib = os.path.join(root, "build", "sim", "lib")

if os.path.isdir(dst):
    shutil.rmtree(dst)
shutil.copytree(src, dst)
p = os.path.join(dst, "project.pbxproj")
text = open(p).read()

def repoint(m):
    line = m.group(0)
    name = re.search(r"/\* (lib[^ ]+\.a) \*/", line).group(1)
    line = re.sub(r'path = "?[^;]+"?;', f'path = "{os.path.join(lib, name)}";', line)
    return line.replace('sourceTree = "<group>";', 'sourceTree = "<absolute>";')

text = re.sub(r"^.*PBXFileReference; lastKnownFileType = archive\.ar;.*$", repoint, text, flags=re.M)
text = re.sub(r"^\t+A1000054 /\* MetalFX\.framework in Frameworks \*/,\n", "", text, flags=re.M)
open(p, "w").write(text)
print("wrote", dst)
