#!/usr/bin/env python3
"""Observe actual Metal options and Vulkan specialization/GPU readback.

Usage: check-metal-library-options-native.py HEADERS LIBMOLTENVK
Each policy runs in a fresh process because the runtime option is process-wide.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
headers, library = (Path(p).resolve() for p in sys.argv[1:3])
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="madeira-metal-options-") as temp:
    obj = Path(temp) / "probe.o"
    exe = Path(temp) / "probe"
    subprocess.run(["xcrun", "clang", "-std=c11", "-Dmain=vulkan_probe_main",
                    "-I"+str(headers), "-c", str(root/"tests/x64/vulkan-cache-specialization.c"),
                    "-o", str(obj)], check=True)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-fblocks",
                    "-framework", "Metal", "-framework", "Foundation",
                    str(root/"tests/vulkan/metal-library-options.mm"), str(obj), str(library),
                    "-Wl,-rpath,"+str(library.parent), "-o", str(exe)], check=True)
    for policy in [None, "default", "size", "SIZE", "0", ""]:
        env = dict(os.environ, MVK_CONFIG_LOG_LEVEL="1")
        env.pop("MADEIRA_VK_METAL_LIBRARY_OPTIMIZATION", None)
        if policy is not None:
            env["MADEIRA_VK_METAL_LIBRARY_OPTIMIZATION"] = policy
        result = subprocess.run([str(exe), "8"], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print("POLICY", repr(policy), result.stdout, flush=True)
        assert result.returncode == 0, "Compiler option selection or real GPU readback failed"
print("PASS default/size/invalid policy reaches real Metal compiler; specialization readback preserved")
