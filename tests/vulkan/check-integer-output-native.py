#!/usr/bin/env python3
"""Actual Vulkan image readback for the opt-in fragment numeric mismatch policy.
Usage: check-integer-output-native.py HEADERS LIBMOLTENVK
"""
from pathlib import Path
import os, subprocess, sys, tempfile
headers, library = (Path(p).resolve() for p in sys.argv[1:3])
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="madeira-integer-output-") as temp:
    exe = Path(temp)/"probe"
    subprocess.run(["xcrun","clang","-std=c11","-Wall","-Wextra","-Werror",
        "-I"+str(headers),str(root/"tests/vulkan/integer-output-readback.c"),
        str(library),"-Wl,-rpath,"+str(library.parent),"-o",str(exe)], check=True)
    cases = [(mode,width,bits,"0") for mode in [None,"0","1","invalid"]
             for width in [1,2,3,4] for bits in ["00000000","3f400000","bf800000"]]
    cases += [(mode,width,"3f400001",kind) for mode in ["0","1"]
              for width in [1,4] for kind in ["1","2"]]
    for mode,width,bits,kind in cases:
        env=dict(os.environ,MVK_CONFIG_LOG_LEVEL="1")
        env.pop("MADEIRA_VK_INTEGER_FRAGMENT_OUTPUTS",None)
        if mode is not None: env["MADEIRA_VK_INTEGER_FRAGMENT_OUTPUTS"]=mode
        r=subprocess.run([str(exe),str(width),bits,kind],env=env,text=True,
                          stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
        print("CASE",mode,width,bits,kind,flush=True)
        if r.returncode: print(r.stdout)
        assert r.returncode==0,"pipeline or GPU readback failed"
        assert "GPU image readback expected=" in r.stdout
    print("PASS",len(cases),"policy/width/value/typed-output cases with actual GPU readbacks")
    env=dict(os.environ,MADEIRA_VK_INTEGER_FRAGMENT_OUTPUTS="1")
    r=subprocess.run([str(exe),"4","3f400000","0","1"],env=env,text=True,
                     stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    if r.returncode: print(r.stdout)
    assert r.returncode==0,"rasterizer discard dereferenced ignored state"
    print("PASS rasterizer-discard ignored-state guard")
