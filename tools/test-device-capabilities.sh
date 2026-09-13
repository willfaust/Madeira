#!/bin/sh
# Unit tests for the DeviceCapabilities policy helpers.
#
# These produce the numbers a release ships with -- the JIT pool size derived
# from the device's jetsam budget, and the parsing of the madeira-*.txt override
# files -- so they are asserted, not eyeballed. Everything under test is a pure
# function: the harness injects the memory budget instead of measuring it, and
# calls the parsers directly instead of touching Documents.
#
# The pool table's first four rows are the point of the whole exercise: every
# device at or below the 4096MB budget of the device this emulator was developed
# against must still get exactly 896MB, or the change would silently move the VA
# floor on the only hardware it has ever been validated on.
#
# Needs a Swift toolchain: Xcode's swiftc on macOS, or any swiftc on Linux.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

SWIFTC=${SWIFTC:-swiftc}
if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "test-device-capabilities: SKIP -- no swiftc on PATH (override with SWIFTC=...)" >&2
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The production file imports Apple-only modules. Redirect the memory probe to
# an injectable function, and off Darwin stand in for sysctl and os/proc.h.
sed -e 's/os_proc_available_memory()/testAvailableMemory()/g' \
    app/Madeira/DeviceCapabilities.swift > "$TMP/DeviceCapabilitiesTest.swift"

SOURCES="$TMP/DeviceCapabilitiesTest.swift"
if [ "$(uname -s)" != "Darwin" ]; then
    sed -i.bak -e 's/^import Darwin$/import Glibc/' -e '/^import os$/d' \
        "$TMP/DeviceCapabilitiesTest.swift"
    rm -f "$TMP/DeviceCapabilitiesTest.swift.bak"
    cat > "$TMP/Shims.swift" <<'SWIFT'
import Foundation
import Glibc

@discardableResult
func sysctlbyname(_ name: UnsafePointer<CChar>!,
                  _ oldp: UnsafeMutableRawPointer!,
                  _ oldlenp: UnsafeMutablePointer<Int>!,
                  _ newp: UnsafeMutableRawPointer!,
                  _ newlen: Int) -> Int32 { return -1 }
SWIFT
    SOURCES="$SOURCES $TMP/Shims.swift"
fi

cat > "$TMP/main.swift" <<'SWIFT'
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation

var testBudgetBytes = 0
func testAvailableMemory() -> Int { return testBudgetBytes }

var failures = 0
func check(_ label: String, _ got: String, _ want: String) {
    let ok = got == want
    if !ok { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL") \(label): got \(got), want \(want)")
}

// MARK: - JIT pool size

print("JIT pool size vs jetsam budget:")
let poolCases: [(budgetMB: Int, poolMB: Int)] = [
    // At or below the development device: must not move.
    (0, 896), (1024, 896), (2048, 896), (4096, 896),
    // Above it: scales proportionally, rounded down to a 32MB multiple.
    (5120, 1120), (6144, 1344), (7168, 1568),
    // And is capped, because the resident set does not grow with the device.
    (8192, 1792), (12288, 1792), (16384, 1792),
]
for c in poolCases {
    testBudgetBytes = c.budgetMB * 1024 * 1024
    check("budget \(c.budgetMB)MB", "\(DeviceCapabilities.recommendedPoolMB())", "\(c.poolMB)")
}

// MARK: - madeira-fex.txt

print("madeira-fex.txt parsing:")
let fexCases: [(text: String, applied: String, rejected: Int)] = [
    ("TSOENABLED=0", "(\"FEX_TSOENABLED\", \"0\")", 0),
    ("tsoenabled = 0", "(\"FEX_TSOENABLED\", \"0\")", 0),
    ("  TSOENABLED=0  ", "(\"FEX_TSOENABLED\", \"0\")", 0),
    ("A=a=b", "(\"FEX_A\", \"a=b\")", 0),
    ("MULTIBLOCK=1, X87REDUCEDPRECISION=1",
     "(\"FEX_MULTIBLOCK\", \"1\"), (\"FEX_X87REDUCEDPRECISION\", \"1\")", 0),
    ("MULTIBLOCK=1\nX87REDUCEDPRECISION=1",
     "(\"FEX_MULTIBLOCK\", \"1\"), (\"FEX_X87REDUCEDPRECISION\", \"1\")", 0),
    // A line with no '=' is a comment; it is not a malformed entry.
    ("# why: CEF crashes without this\ngarbage\n", "", 0),
    // These name a key but carry no usable value. Applying either would put a
    // wrong value into the environment, which fails quietly at run time.
    ("TSOENABLED=", "", 1),
    ("TSOENABLED=0 MULTIBLOCK=1", "", 1),
    ("=1", "", 1),
    ("", "", 0),
]
for c in fexCases {
    let got = DeviceCapabilities.fexConfigEntries(from: c.text)
    let rendered = got.applied.map { "(\"\($0.key)\", \"\($0.value)\")" }.joined(separator: ", ")
    check("\(String(reflecting: c.text))",
          "[\(rendered)] rejected=\(got.rejected.count)",
          "[\(c.applied)] rejected=\(c.rejected)")
}

// MARK: - madeira-resolution.txt

print("madeira-resolution.txt parsing:")
let resCases: [(text: String, want: String)] = [
    ("1280x720", "(w: 1280, h: 720)"),
    ("1920X1080", "(w: 1920, h: 1080)"),
    ("  640x480  ", "(w: 640, h: 480)"),
    // Out of the accepted range, or not a size at all.
    ("100x100", "nil"), ("5000x500", "nil"), ("abc", "nil"),
    ("1024", "nil"), ("", "nil"), ("1024x", "nil"), ("x768", "nil"),
]
for c in resCases {
    let got = DeviceCapabilities.parseDesktopResolution(c.text)
    check("\(String(reflecting: c.text))", got.map { "\($0)" } ?? "nil", c.want)
}

// MARK: - madeira-dxmt.txt / MetalFX
//
// DXMT reads the upscale factor from DXMT_CONFIG but gates the scaler on a
// separate environment variable, so this parser is the only thing that makes a
// hand-written `d3d11.metalSpatialUpscaleFactor` do anything at all. A false
// negative is silent (the option is inert); a false positive is not (the
// variable would arm the scaler at a factor of 1, i.e. a wasted 1:1 blit), so
// both directions are pinned here.
print("madeira-dxmt.txt MetalFX parsing:")
let fxCases: [(text: String, want: Bool)] = [
    ("d3d11.metalSpatialUpscaleFactor=2.0", true),
    ("d3d11.metalSpatialUpscaleFactor=1.5", true),
    ("d3d11.metalSpatialUpscaleFactor=1.33", true),
    ("d3d11.metalSpatialUpscaleFactor=1.01", true),
    ("  d3d11.metalSpatialUpscaleFactor = 2  ", true),
    ("d3d11.mipClampBC=1\nd3d11.metalSpatialUpscaleFactor=2.0", true),
    ("# d3d11.metalSpatialUpscaleFactor=2.0", false),
    // 1.0 is what DXMT's own clamp turns "off" into, so arming for it buys a
    // scaler with nothing to scale.
    ("d3d11.metalSpatialUpscaleFactor=1.0", false),
    ("d3d11.metalSpatialUpscaleFactor=1", false),
    ("d3d11.metalSpatialUpscaleFactor=0.5", false),
    ("d3d11.metalSpatialUpscaleFactor=yes", false),
    ("d3d11.metalSpatialUpscaleFactor=", false),
    ("d3d11.metalSpatialUpscaleFactor=2.0 extra", false),
    ("d3d11.mipClampBC=1", false),
    ("", false),
]
for c in fxCases {
    check("\(String(reflecting: c.text))",
          "\(DeviceCapabilities.dxmtConfigArmsMetalFX(c.text))", "\(c.want)")
}

// The file is one option per line; DXMT only parses ";" chunks. Handed the
// file verbatim it applies the first line and drops the rest, which is exactly
// the failure mode a second option would have introduced.
print("madeira-dxmt.txt inline form:")
let inlineCases: [(text: String, want: String)] = [
    ("d3d11.mipClampBC=1", "d3d11.mipClampBC=1"),
    ("d3d11.mipClampBC=1\nd3d11.metalSpatialUpscaleFactor=2.0",
     "d3d11.mipClampBC=1;d3d11.metalSpatialUpscaleFactor=2.0"),
    ("  a=1  \n\n  b=2  ", "a=1;b=2"),
    ("a=1;b=2", "a=1;b=2"),
    // DXMT ends an unquoted value at the first whitespace and strips the quotes
    // from a quoted one, so a description with spaces must arrive quoted and must
    // survive the fold untouched. The Settings code writes these three lines; if
    // the fold or the quoting broke, the renderer would be told the adapter is
    // called "AMD" and nothing here would fail.
    ("dxgi.customDeviceDesc=\"AMD Radeon Pro 5300M\"\ndxgi.customVendorId=1002\ndxgi.customDeviceId=7340",
     "dxgi.customDeviceDesc=\"AMD Radeon Pro 5300M\";dxgi.customVendorId=1002;dxgi.customDeviceId=7340"),
    ("\n\n", ""),
    ("", ""),
]
for c in inlineCases {
    check("\(String(reflecting: c.text))",
          DeviceCapabilities.dxmtConfigInline(c.text), c.want)
}
// The normalizer and the arm check have to agree on the separator, or a
// two-option file arms the variable and then never reads the factor.
let twoOptionFile = "d3d11.mipClampBC=1\nd3d11.metalSpatialUpscaleFactor=2.0"
let twoOptionInline = DeviceCapabilities.dxmtConfigInline(twoOptionFile)
check("the normalizer keeps both options",
      twoOptionInline, "d3d11.mipClampBC=1;d3d11.metalSpatialUpscaleFactor=2.0")
check("and the arm check still finds the factor after normalizing",
      "\(DeviceCapabilities.dxmtConfigArmsMetalFX(twoOptionInline))", "true")

// The renderer cache is relocated out of Library/Caches, which iOS may empty.
// An unset variable is a working cache in the old place; a variable pointing
// somewhere unwritable disables the cache, so the path has to be absolute and
// the directory has to exist by the time it is handed over.
print("DXMT shader cache location:")
check("the variable name is DXMT's",
      DeviceCapabilities.DXMTShaderCache.pathVariable, "DXMT_SHADER_CACHE_PATH")
if let url = DeviceCapabilities.DXMTShaderCache.directoryURL() {
    check("the cache directory is named",
          url.lastPathComponent, DeviceCapabilities.DXMTShaderCache.directoryName)
} else {
    check("a container always has an Application Support directory", "nil", "a URL")
}
if let path = DeviceCapabilities.DXMTShaderCache.preparedPath() {
    check("the prepared path is absolute", "\(path.hasPrefix("/"))", "true")
    check("and is a directory that exists",
          "\(FileManager.default.fileExists(atPath: path))", "true")
    check("and ends with the cache directory name",
          (path as NSString).lastPathComponent,
          DeviceCapabilities.DXMTShaderCache.directoryName)
} else {
    check("the cache directory can be prepared", "nil", "a path")
}

// A durable cache is one nothing else clears, so the launch path has to be able
// to throw away a database a kill truncated mid-write. Only the shader DBs are
// touched: anything else in that directory is not ours.
print("DXMT shader cache repairs:")
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("dxmt-cache-test-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
func write(_ name: String, _ bytes: [UInt8]) {
    try? Data(bytes).write(to: scratch.appendingPathComponent(name))
}
write("shaders_320.db", Array("SQLite format 3\0".utf8) + [0, 0, 0, 0])
write("shaders_320.db-wal", [0xAA])
write("shaders_310.db", [0x00, 0x01, 0x02])
write("shaders_310.db-wal", [0xBB])
write("shaders_999.db", [])
write("keep-me.txt", [0x00])
let discarded = DeviceCapabilities.DXMTShaderCache.discardUnreadableDatabases(in: scratch)
check("a truncated database is discarded",
      discarded.joined(separator: ","), "shaders_310.db,shaders_999.db")
check("a valid database is kept",
      "\(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("shaders_320.db").path))",
      "true")
check("and keeps the valid database's write-ahead log",
      "\(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("shaders_320.db-wal").path))",
      "true")
check("a discarded database's write-ahead log goes with it",
      "\(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("shaders_310.db-wal").path))",
      "false")
check("a file that is not a shader database is left alone",
      "\(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("keep-me.txt").path))",
      "true")
let missing = scratch.appendingPathComponent("missing")
let secondPass = DeviceCapabilities.DXMTShaderCache.discardUnreadableDatabases(in: scratch)
let absentPass = DeviceCapabilities.DXMTShaderCache.discardUnreadableDatabases(in: missing)
check("a second pass has nothing left to do", "\(secondPass.count)", "0")
check("an absent directory is not an error", "\(absentPass.count)", "0")
try? FileManager.default.removeItem(at: scratch)

print(failures == 0
      ? "test-device-capabilities: OK"
      : "test-device-capabilities: \(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
SWIFT

# shellcheck disable=SC2086
"$SWIFTC" -O -o "$TMP/test-device-capabilities" $SOURCES "$TMP/main.swift"
"$TMP/test-device-capabilities"
