#!/usr/bin/env python3
"""WoW64 launch routing in WineProcessBridge.m; no Wine, no app build.

Part A reads the launch function and checks that a target which is not a 32-bit PE takes
the path it took before: the name heuristic that picks the session core is untouched and
is overridden only for an i386 target, every WoW64 step (syswow64 farm, wbem, winsxs, the
host-probe export) is behind "the bundle carries the i386 set" or "the target is i386",
and ios_main_image_i386 is published before __wine_main. Part B compiles the production
madeira_pe_machine and madeira_target_machine against synthetic PE files and a fake bundle.
"""
from pathlib import Path
import re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "app/Madeira/WineProcessBridge.m").read_text().replace("\r\n", "\n")

def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]

# ---- Part A: the launch function
thread = function(src, "static void *wine_process_thread(void *arg) {")
upstream_ec = """BOOL use_arm64ec = (force_ec && *force_ec == '1') ||
                           (strstr(madeira_exe, "x64") != NULL) ||
                           (strchr(madeira_exe, '\\\\') != NULL);"""
assert upstream_ec in thread, "the session-core heuristic is upstream's, verbatim"
assigns = re.findall(r"use_arm64ec\s*=[^=][^;]*;", thread)
assert assigns[1:] == ["use_arm64ec = NO;"], assigns
assert "if (is_i386_target) use_arm64ec = NO;" in thread, "only an i386 target changes the core"
assert "const BOOL is_i386_target = has_i386_set && target_machine == MADEIRA_IMAGE_FILE_MACHINE_I386;" in thread
farm = thread[thread.index("if (has_i386_set) {"):]
farm = farm[:farm.index("/* ml719: REPAIR THE SHELL FOLDERS.")]
assert "madeira_link_syswow64(fm, prefix, bundlePath);" in farm
# #84: syswow64\\wbem and the x86 side-by-side store are seeded for every session that
# has the i386 farm (a 64-bit target starts 32-bit children too), not for i386 targets only.
assert "madeira_link_syswow64_wbem(" in farm and "madeira_seed_winsxs_x86(" in farm, "wbem/winsxs with the i386 farm"
assert "is_i386_target" not in farm, "wbem/winsxs no longer depend on the target's machine"
for call in ["madeira_link_syswow64(", "madeira_link_syswow64_wbem(", "madeira_seed_winsxs_x86(",
             "madeira_publish_host_probe()"]:
    assert thread.count(call) == 1, call
assert thread.index("ios_main_image_i386 = is_i386_target ? 1 : 0;") < thread.index("__wine_main(argc, argv);")
# Every session: both FEX modules read the probe (an A12/A13 64-bit game needs FlagM/FlagM2 off).
assert "        madeira_publish_host_probe();   /* both FEX modules read it" in thread
exe = thread[thread.index("char exe_path[512];"):]
exe = exe[:exe.index("// Optional MADEIRA_ARGS")]
i386_branch = exe[exe.index("} else if (is_i386_target) {"):]
assert i386_branch.index('"C:\\\\windows\\\\syswow64\\\\%s"') < i386_branch.index("} else {"), exe
assert 'snprintf(exe_path, sizeof(exe_path), "C:\\\\windows\\\\system32\\\\%s", madeira_exe);' in exe
sxs = function(src, "static void madeira_seed_winsxs_x86(")
assert "x86_%s_%s_%s_none_deadbeef" in sxs and 'processorArchitecture=\\"x86\\"' in sxs
assert "arm64" not in sxs and "amd64" not in sxs, "only x86 assemblies are written"
print("PASS: non-i386 targets keep the upstream core choice and exe path; the i386 farm, wbem and winsxs come with the farm")

# ---- Part B: the machine probe
pe_machine = function(src, "static uint16_t madeira_pe_machine(")
target = function(src, "static uint16_t madeira_target_machine(")
target = target.replace("NSString *bundle", "const char *bundle").replace("bundle.fileSystemRepresentation", "bundle")
code = r"""
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <assert.h>
""" + '\n#include "' + str(root / 'app/Madeira/SteamStorageNative.h') + '"\n' + pe_machine + "\n" + target + r"""
int main(int argc, char **argv)
{
    const char *d = argv[1];
    char prefix[PATH_MAX], bundle[PATH_MAX], p[PATH_MAX];
    snprintf(prefix, sizeof(prefix), "%s/prefix", d);
    snprintf(bundle, sizeof(bundle), "%s/bundle", d);
    snprintf(p, sizeof(p), "%s/pe32.exe", d);     assert(madeira_pe_machine(p) == 0x14c);
    snprintf(p, sizeof(p), "%s/pe64.exe", d);     assert(madeira_pe_machine(p) == 0x8664);
    snprintf(p, sizeof(p), "%s/text.exe", d);     assert(madeira_pe_machine(p) == 0);
    snprintf(p, sizeof(p), "%s/short.exe", d);    assert(madeira_pe_machine(p) == 0);
    snprintf(p, sizeof(p), "%s/badlfa.exe", d);   assert(madeira_pe_machine(p) == 0);
    snprintf(p, sizeof(p), "%s/missing.exe", d);  assert(madeira_pe_machine(p) == 0);
    assert(madeira_pe_machine(NULL) == 0 && madeira_pe_machine("") == 0);
    /* full paths under drive_c, backslashes and spaces */
    assert(madeira_target_machine("C:\\Program Files\\App Dir\\app32.exe", prefix, bundle) == 0x14c);
    assert(madeira_target_machine("c:\\Program Files\\App Dir\\app64.exe", prefix, bundle) == 0x8664);
    /* E: requires both the registered mapping and its current identity. */
    assert(madeira_target_machine("E:\\Games\\app32.exe", prefix, bundle) == 0);
    setenv("MADEIRA_EXTERNAL_LIBRARY_ID", "12345678-1234-1234-1234-123456789abc", 1);
    assert(madeira_target_machine("E:\\Games\\app32.exe", prefix, bundle) == 0x14c);
    assert(madeira_target_machine("e:\\Games\\app64.exe", prefix, bundle) == 0x8664);
    assert(madeira_storage_native(prefix, "E:\\Games", p, sizeof(p)) == 0);
    assert(madeira_storage_native(prefix, "E:\\Games\\..\\escape", p, sizeof(p)) != 0);
    assert(madeira_storage_native(prefix, "E:\\escape\\app32.exe", p, sizeof(p)) != 0);
    assert(madeira_storage_native(prefix, "E:\\missing", p, sizeof(p)) != 0);
    assert(madeira_storage_native(prefix, "E:\\Games", p, 8) != 0);
    setenv("MADEIRA_EXTERNAL_LIBRARY_ID", "aaaaaaaa-1234-1234-1234-123456789abc", 1);
    assert(madeira_target_machine("E:\\Games\\app32.exe", prefix, bundle) == 0);
    unsetenv("MADEIRA_EXTERNAL_LIBRARY_ID");
    assert(madeira_target_machine("C:\\Program Files\\App Dir\\none.exe", prefix, bundle) == 0);
    /* other forms are not probed */
    assert(madeira_target_machine("D:\\app32.exe", prefix, bundle) == 0);
    assert(madeira_target_machine("\\Program Files\\App Dir\\app32.exe", prefix, bundle) == 0);
    /* bare names: a name in a 64-bit farm is 64-bit even if i386-windows has it too */
    assert(madeira_target_machine("both.exe", prefix, bundle) == 0);
    assert(madeira_target_machine("only32.exe", prefix, bundle) == 0x14c);
    assert(madeira_target_machine("nowhere.exe", prefix, bundle) == 0);
    puts("probe ok");
    return 0;
}
"""

def pe(machine, lfanew=0x80):
    b = bytearray(lfanew + 24)
    b[0:2] = b"MZ"; b[0x3c:0x40] = lfanew.to_bytes(4, "little")
    b[lfanew:lfanew + 4] = b"PE\0\0"; b[lfanew + 4:lfanew + 6] = machine.to_bytes(2, "little")
    return bytes(b)

with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    (t / "pe32.exe").write_bytes(pe(0x14c)); (t / "pe64.exe").write_bytes(pe(0x8664))
    (t / "text.exe").write_bytes(b"not a PE file at all, just some text" * 4)
    (t / "short.exe").write_bytes(b"MZ\0\0")
    bad = bytearray(pe(0x14c)); bad[0x3c:0x40] = (32 << 20).to_bytes(4, "little"); (t / "badlfa.exe").write_bytes(bad)
    app = t / "prefix/drive_c/Program Files/App Dir"; app.mkdir(parents=True)
    (app / "app32.exe").write_bytes(pe(0x14c)); (app / "app64.exe").write_bytes(pe(0x8664))
    external = t / 'external/Games'; external.mkdir(parents=True)
    (external / 'app32.exe').write_bytes(pe(0x14c)); (external / 'app64.exe').write_bytes(pe(0x8664))
    (external.parent / '.madeira-library-id').write_text('12345678-1234-1234-1234-123456789abc')
    (external.parent / 'escape').symlink_to(app, target_is_directory=True)
    (t / 'prefix/dosdevices').mkdir()
    (t / 'prefix/dosdevices/e:').symlink_to(external.parent, target_is_directory=True)
    for farm in ["aarch64-windows", "arm64ec-windows", "i386-windows"]:
        (t / "bundle" / farm).mkdir(parents=True)
    (t / "bundle/aarch64-windows/both.exe").write_bytes(pe(0xaa64))
    (t / "bundle/i386-windows/both.exe").write_bytes(pe(0x14c))
    (t / "bundle/i386-windows/only32.exe").write_bytes(pe(0x14c))
    c = t / "check.c"; exe = t / "check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-Werror=implicit-function-declaration", str(c), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe), str(t)], check=True, capture_output=True, text=True)
    assert "probe ok" in out.stdout, out.stdout + out.stderr
print("PASS: PE machine probe: PE32/PE32+/non-PE/truncated/huge e_lfanew; drive_c paths; bare names prefer the 64-bit farms")
print("PASS: registered E: machine and working-directory paths; missing identity, different identity, traversal and symlink escapes refused")
