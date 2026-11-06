#!/usr/bin/env python3
"""Exercise the real build routing with stub compilers, and source-fetch refusals."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PIN = "b39d173ca9369c19fda2635be6655d308067e52d"
FETCH = ROOT / "build/mesa-ios/fetch-playport.py"

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    unknown = root / "unknown"
    source = unknown / ("mesa-" + PIN)
    source.mkdir(parents=True)
    (source / "keep-me").write_text("user data")
    result = subprocess.run(["python3", str(FETCH), str(unknown)], capture_output=True, text=True)
    assert result.returncode and (source / "keep-me").read_text() == "user data"
    bad = root / "bad"
    bad.mkdir()
    (bad / ("mesa-" + PIN + ".tar.gz")).write_bytes(b"not the pinned source")
    result = subprocess.run(["python3", str(FETCH), str(bad)], capture_output=True, text=True)
    assert result.returncode and "hash mismatch" in result.stderr
    assert not (bad / ("mesa-" + PIN)).exists()

    tools = root / "bin"
    tools.mkdir()
    log = root / "commands"
    for command, script in {
        "patch": 'echo "patch:$*" >> "$TEST_LOG"',
        "xcrun": 'echo /mock-sdk',
        "meson": 'echo "meson:$*" >> "$TEST_LOG"; mkdir -p "$2"; touch "$2/build.ninja"',
        "ninja": 'mkdir -p "$2/src/kosmickrisp/vulkan"; touch "$2/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"',
        "install_name_tool": 'exit 0',
    }.items():
        path = tools / command
        path.write_text("#!/bin/sh\nset -eu\n" + script + "\n")
        path.chmod(0o755)
    for experimental in [False, True]:
        work = root / ("playport" if experimental else "release")
        source = work / ("mesa-" + PIN if experimental else "mesa-26.2.4")
        (source / "src/kosmickrisp").mkdir(parents=True)
        (source / "src/kosmickrisp/meson.build").touch()
        if experimental:
            (source / ".madeira-source-pin").write_text(PIN + "\n")
        clc = work / "host-tools/bin/kk_clc"
        clc.parent.mkdir(parents=True)
        clc.write_text("#!/bin/sh\nexit 0\n")
        clc.chmod(0o755)
        log.write_text("")
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], KK_WORK=str(work), TEST_LOG=str(log))
        for key in ["KK_MESA_SRC", "KK_PROFILE", "KK_SHADER_CACHE", "KK_OUT"]:
            env.pop(key, None)
        name = "build-playport-kosmickrisp.sh" if experimental else "build-kosmickrisp.sh"
        subprocess.run(["bash", str(ROOT / "build/mesa-ios" / name)], env=env, check=True, capture_output=True)
        recorded = log.read_text()
        assert "-Dshader-cache=" + ("enabled" if experimental else "disabled") in recorded
        applied = recorded.count("patch:")
        assert applied == (19 if experimental else 6), (experimental, applied)
        assert (work / "out/libvulkan_kosmickrisp.dylib").exists()
print("PASS: default and experimental build routing; 6/19 patch series; source hash and user-file protection")
