"""The host FFmpeg the media checks link against: built from the tracked tarball with a check's
configure flags, and cached in ~/.cache/madeira-host-ffmpeg/7.1.5-<tag><hash of the flags>.

Checks with the same flags share one build (check-wma-decoder.py and check-wg-resampler.py;
check-wg-parser-asf.py and check-wmv-transform.py), and run-all.py runs checks at the same time.
Two configures in one build directory break it ("extraneous 'endif'" in ffbuild/config.mak) and
both checks fail, and a check that saw a library appear could link against a half-installed
prefix. So the prefix is looked at and built under a lock: a check waits for a build in progress,
and a build starts from a clean build directory.
"""
import fcntl, hashlib, os, shutil, subprocess
from pathlib import Path

VERSION = "7.1.5"


def host_ffmpeg(flags, tarball, tag="", override=None):
    """The prefix (include/, lib/) of the host build for `flags`, built if needed.
    `override`: a prefix named in the environment, used as it is."""
    if override:
        return Path(override)
    key = hashlib.sha256(" ".join(flags).encode()).hexdigest()[:12]
    prefix = Path.home() / ".cache/madeira-host-ffmpeg" / ("%s-%s%s" % (VERSION, tag, key))
    prefix.parent.mkdir(parents=True, exist_ok=True)
    with open(str(prefix) + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not all((prefix / "lib" / a).exists() for a in ("libavformat.a", "libavcodec.a")):
            _build(prefix, flags, tarball)
    return prefix


def _build(prefix, flags, tarball):
    assert tarball and Path(tarball).exists(), \
        "no FFmpeg tarball at %s (tracked in build/ffmpeg/src) and no MADEIRA_FFMPEG_TARBALL" % tarball
    src = Path(str(prefix) + "-src")
    configure = src / ("ffmpeg-%s/configure" % VERSION)
    if not configure.exists():
        shutil.rmtree(src, ignore_errors=True)
        src.mkdir(parents=True)
        subprocess.run(["tar", "-xJf", str(tarball), "-C", str(src)], check=True)
    # A build directory left by an interrupted run starts again.
    bld = Path(str(prefix) + "-build")
    shutil.rmtree(bld, ignore_errors=True)
    bld.mkdir(parents=True)
    print("building host FFmpeg into", prefix, flush=True)
    with open(str(bld) + ".log", "w") as log:
        for cmd in ([str(configure), "--prefix=" + str(prefix), "--cc=cc"] + list(flags),
                    ["make", "-j%d" % (os.cpu_count() or 4)],
                    ["make", "install"]):
            subprocess.run(cmd, cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
