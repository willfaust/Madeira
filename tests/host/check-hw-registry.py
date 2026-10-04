#!/usr/bin/env python3
"""wineboot's volatile hardware keys on iOS; no Wine runs.

1. Wiring, read from the files: loader_ios.c calls ios_hw_registry_publish in
   start_main_thread after init_cpu_info and before init_startup_info;
   server_ios.c reads MADEIRA_HW_REGISTRY once and creates every key through
   the volatile level-by-level helper.
2. The values (build/ntdll-unix/hw_registry_ios.h) compiled and run on the
   host: identifier, vendor, brand, feature set, ~MHz from the counter
   frequency, switch and count parsing.
3. FEX ($FEX_SRC, default ./FEX): every mirrored number read back out of
   CPUID.cpp/CPUID.h, Source/Windows/Common/CPUFeatures.cpp, the FEX winternl.h,
   Core.cpp, Context.h and Config.json.in.
4. wineboot ($WINE_SRC, default ./wine): the value names and constants, and
   the SMBIOS rules -- wineboot's own find_smbios_entry / get_smbios_string /
   create_bios_*_values and ntdll's own append_smbios_* generator, extracted and
   compiled, run against hw_registry_ios.h on Wine's generic and Apple tables,
   an SMBIOS 2.3 style table and tables with empty strings; plus a fuzz run of
   the parser under ASan/UBSan where the host compiler has them.
5. The publish code (server_ios.c between the hw-registry-test marks)
   compiled against a fake registry with Wine 11's parent rule and a fake
   NtQuerySystemInformation serving the generated tables: keys, volatility,
   values, MADEIRA_HW_REGISTRY=0, no SMBIOS, zero counter frequency, repeated
   runs, Session Manager\\Environment untouched.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
n_dir = root / "build/ntdll-unix"
wine = Path(os.environ.get("WINE_SRC", root / "wine"))
fex = Path(os.environ.get("FEX_SRC", root / "FEX"))
CC = os.environ.get("CC", "cc")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def func(src, sig):
    """The definition: the last occurrence (prototypes come first)."""
    body = src[src.rindex(sig):]
    return body[:body.index("\n}\n") + 3]


def run_c(srcs, exe, flags=(), extra_files=()):
    """Compile `srcs` ({name: text}) into `exe`; return its stdout or None."""
    paths = []
    for name, text in srcs.items():
        p = exe.parent / name
        p.write_text(text)
        paths.append(str(p))
    cmd = [CC, "-std=gnu11", "-O1", "-Wall", "-Wno-unused-function", "-Wno-format-truncation",
           "-I", str(n_dir)] + list(flags) + paths + ["-o", str(exe)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stderr[-4000:])
        return None
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-2000:])
        return None
    return r.stdout


loader = (n_dir / "loader_ios.c").read_text()
server = (n_dir / "server_ios.c").read_text()
header = (n_dir / "hw_registry_ios.h").read_text()
build = (n_dir / "build.sh").read_text()

# ------------------------------------------------------------------ 1. wiring
smt = func(loader, "static void start_main_thread(void)")
i_cpu, i_pub, i_env = smt.find("    init_cpu_info();"), smt.find("ios_hw_registry_publish();"), smt.find("unix_init_startup_info();")
check("start_main_thread: init_cpu_info -> ios_hw_registry_publish -> unix_init_startup_info",
      0 <= i_cpu < i_pub < i_env)
check("the call is iOS-only and declared next to it",
      re.search(r"#ifdef WINE_IOS\n(?:\s*/\*.*?\*/\n)?\s*\{\n\s*extern void ios_hw_registry_publish\(void\);\n"
                r"\s*WINE_IOS_LOG\(\"ios_hw_registry_publish...\"\);\n\s*ios_hw_registry_publish\(\);\n\s*\}\n#endif",
                smt, re.S) is not None)
check("only start_main_thread (the session's first process) publishes",
      loader.count("ios_hw_registry_publish();") == 1 and server.count("ios_hw_registry_publish();") == 0)
init_proc = server.index("size_t server_init_process(void)")
wine_ios_blocks = server[:init_proc]
check("and inside the WINE_IOS block that ends before server_init_process",
      wine_ios_blocks.rindex("#ifdef WINE_IOS") < server.index("void ios_hw_registry_publish(void)")
      < wine_ios_blocks.rindex("#endif"))
check("build.sh compiles server_ios.c and loader_ios.c (no new translation unit)",
      'compile_one "$BUILD_DIR/server_ios.c" "server"' in build and 'compile_one "$BUILD_DIR/loader_ios.c" "loader"' in build)
region = server[server.index("/* hw-registry-test:begin"):server.index("/* hw-registry-test:end */")]
pub = func(server, "void ios_hw_registry_publish(void)")
check("MADEIRA_HW_REGISTRY read once, through hwreg_enabled",
      server.count('getenv( "MADEIRA_HW_REGISTRY" )') == 1 and 'if (!hwreg_enabled( getenv( "MADEIRA_HW_REGISTRY" ) ))' in pub)
check("every HARDWARE key is made by the volatile level-by-level helper",
      len(re.findall(r"ios_hw_key\( machine, ", pub)) == 4 and "NtCreateKey" not in pub)
check("Session Manager\\Environment is not touched", "Environment" not in pub and "NtOpenKey" not in pub)
hk = func(server, "static HANDLE ios_hw_key( const char *base, const char *subpath )")
check("ios_hw_key creates each missing level REG_OPTION_VOLATILE (inside the test region)",
      "NtCreateKey( &key, KEY_ALL_ACCESS, &attr, 0, NULL, REG_OPTION_VOLATILE, NULL )" in hk and hk in region)
check("one [hw-registry] line per session (or the off line)",
      pub.count("wine_log_write(") == 3 and pub.count('"[hw-registry] ') == 3)
check("the CNTFRQ_EL0 read stays outside the test region (the harness supplies its own)",
      "CNTFRQ_EL0" not in region and "static uint64_t ios_hw_cntfrq(void)" in server)

with tempfile.TemporaryDirectory(prefix="madeira-hwreg-") as tmpd:
    tmp = Path(tmpd)

    # ------------------------------------------------------------ 2. values
    out = run_c({"values.c": r'''
#include "hw_registry_ios.h"
static void show( const char *tag, unsigned long long cntfrq )
{
    struct hwreg_cpu c;
    hwreg_fex_cpu( &c, cntfrq );
    printf( "%s|%s|%s|%s|%u|%04x|%08x|%u\n", tag, c.identifier, c.vendor, c.brand, c.level, c.revision,
            (unsigned)c.feature_set, (unsigned)c.mhz );
}
int main( void )
{
    show( "plain", 24000000 );
    show( "1ghz", 1000000000 );
    show( "19.2", 19200000 );
    show( "zero", 0 );
    printf( "enabled %d %d %d %d %d\n", hwreg_enabled( NULL ), hwreg_enabled( "" ), hwreg_enabled( "0" ),
            hwreg_enabled( "1" ), hwreg_enabled( "yes" ) );
    printf( "count %u %u %u %u\n", hwreg_cpu_count( 0 ), hwreg_cpu_count( 6 ), hwreg_cpu_count( 64 ),
            hwreg_cpu_count( 200 ) );
    printf( "base %08x\n", (unsigned)HWREG_FEX_FEATURES );
    return 0;
}
'''}, tmp / "values")
    check("hw_registry_ios.h compiles warning-free and runs", out is not None)
    out = out or ""
    check("Identifier/vendor/brand/level/revision: Intel64 Family 6 Model 166 Stepping 1, GenuineIntel, "
          "'Unknown ARM CPU', 6, a601",
          "plain|Intel64 Family 6 Model 166 Stepping 1|GenuineIntel|Unknown ARM CPU|6|a601|" in out)
    check("FeatureSet 0x2379ffff (FEX baseline + SSE4.2)",
          "plain|Intel64 Family 6 Model 166 Stepping 1|GenuineIntel|Unknown ARM CPU|6|a601|2379ffff|1536\n" in out)
    check("~MHz = FEX's scaled TSC: 24 MHz -> 1536, 1 GHz -> 1000, 19.2 MHz -> 1228, 0 -> 0",
          out.split("1ghz|")[-1].split("\n")[0].endswith("|1000") and out.split("19.2|")[-1].split("\n")[0].endswith("|1228")
          and out.split("zero|")[-1].split("\n")[0].endswith("|0"))
    check("MADEIRA_HW_REGISTRY: 0 -> off, unset/empty/1/other -> on", "enabled 1 1 0 1 1\n" in out)
    check("one key per processor, clamped to 1..64", "count 1 6 64 64\n" in out)
    base = int(re.search(r"base ([0-9a-f]+)", out).group(1), 16) if "base " in out else -1

    # ------------------------------------------------------------ 3. FEX
    cpuid_cpp = fex / "FEXCore/Source/Interface/Core/CPUID.cpp"
    if not cpuid_cpp.exists():
        print("note: %s not checked out (set FEX_SRC); FEX checks skipped" % cpuid_cpp)
    else:
        cpp = cpuid_cpp.read_text()
        h = (fex / "FEXCore/Source/Interface/Core/CPUID.h").read_text()
        cf = (fex / "Source/Windows/Common/CPUFeatures.cpp").read_text()
        wt = (fex / "Source/Windows/include/winternl.h").read_text()
        core = (fex / "FEXCore/Source/Interface/Core/Core.cpp").read_text()
        ctx = (fex / "FEXCore/Source/Interface/Context/Context.h").read_text()
        cfgj = (fex / "FEXCore/Source/Interface/Config/Config.json.in").read_text()
        hdef = dict((k, v.strip().rstrip("uU") if v.strip().startswith("0x") else v.strip())
                    for k, v in re.findall(r"^#define (HWREG_\w+)[ \t]+([^\n]*?)[ \t]*(?:/\*[^\n]*)?$", header, re.M))
        check("FEX: CPUID_AMD stays undefined (Intel branch)",
              "// #define CPUID_AMD" in h and not re.search(r"^#define CPUID_AMD", h + cpp, re.M))
        fam = re.search(r"#else\nconstexpr uint32_t FAMILY_IDENTIFIER = GenerateFamily\(CPUFamily \{(.*?)\}\);", cpp, re.S)
        fields = dict(re.findall(r"\.(\w+) = (\w+),", fam.group(1))) if fam else {}
        want = {"Stepping": "HWREG_FEX_STEPPING", "Model": "HWREG_FEX_MODEL", "ExtendedModel": "HWREG_FEX_EXT_MODEL",
                "FamilyID": "HWREG_FEX_FAMILY", "ExtendedFamilyID": "HWREG_FEX_EXT_FAMILY"}
        check("FEX: Intel FAMILY_IDENTIFIER fields = ours (%s)" % fields,
              fam is not None and all(k in fields and int(fields[k], 0) == int(hdef[v], 0) for k, v in want.items())
              and fields.get("ProcessorType") == "0")
        vend = [int(re.search(r"CPUID_VENDOR_INTEL%d = (0x[0-9A-Fa-f]+)" % i, h).group(1), 16) for i in (1, 2, 3)]
        vstr = b"".join(v.to_bytes(4, "little") for v in vend).decode()
        f0 = func(cpp, "FEXCore::CPUID::FunctionResults CPUIDEmu::Function_0h(uint32_t Leaf) const {")
        check("FEX: leaf 0 vendor (EBX, EDX, ECX) = %s = HWREG_FEX_VENDOR" % vstr,
              vstr == hdef["HWREG_FEX_VENDOR"].strip('"') and "Res.ebx = CPUID_VENDOR_INTEL1;\n  Res.edx = CPUID_VENDOR_INTEL2;\n"
              "  Res.ecx = CPUID_VENDOR_INTEL3;" in f0)
        ios = cf[cf.index("#ifdef FEX_IOS_HOST"):cf.index("HKEY Key = OpenProcessorKey(0);")]
        check("FEX iOS FetchHostFeatures: one MIDR, 0, and SupportsCRC set",
              ios.count("HostFeatures.CPUMIDRs.push_back(") == 1 and "HostFeatures.CPUMIDRs.push_back(0u);" in ios
              and "HostFeatures.SupportsCRC = true;" in ios)
        check("FEX: the host-probe override (CRC=0 etc.) is WOW64-only",
              "#if defined(FEX_IOS_HOST) && !defined(ARCHITECTURE_arm64ec)" in ios
              and ios.index("#if defined(FEX_IOS_HOST) && !defined(ARCHITECTURE_arm64ec)") < ios.index('Absent("CRC")'))
        table = re.findall(r"\{(0x[0-9a-fA-F]+), (0x?[0-9a-fA-F]*|0), ([01]), ProductNames::(\w+)\}", cpp)
        first0 = next((t for t in table if int(t[0], 16) == 0 and int(t[1], 0) == 0), None)
        unk = re.search(r'static const char ARM_UNKNOWN\[\] = "([^"]*)";', cpp)
        check("FEX: MIDR 0 -> ARM_UNKNOWN = %r = HWREG_FEX_BRAND" % (unk.group(1) if unk else None),
              first0 is not None and first0[3] == "ARM_UNKNOWN" and unk and unk.group(1) == hdef["HWREG_FEX_BRAND"].strip('"')
              and "uint8_t Implementer = MIDR >> 24;\n    uint16_t Part = (MIDR >> 4) & 0xFFF;" in cpp)
        check("FEX: brand leaves copy PerCPUData ProductName (16 bytes each)",
              "memcpy(&Res, Data.ProductName, std::min(strlen(Data.ProductName), sizeof(FEXCore::CPUID::FunctionResults)));" in cpp
              and "Data.ProductName + 16" in cpp and "Data.ProductName + 32" in cpp)
        names = re.search(r"CpuInfo\.ProcessorFeatureBits = (CPU_FEATURE_\w+(?:\s*\|\s*CPU_FEATURE_\w+)*);", cf)
        names = re.findall(r"CPU_FEATURE_\w+", names.group(1)) if names else []
        vals = dict((k, int(v, 16)) for k, v in re.findall(r"#define (CPU_FEATURE_\w+) (0x[0-9a-fA-F]+)", wt))
        fexbase = 0
        for nme in names:
            fexbase |= vals[nme]
        ours = [m for m in re.findall(r"HWREG_(CPU_FEATURE_\w+)", header.split("#define HWREG_FEX_FEATURES", 1)[1].split("\n\n")[0])]
        check("FEX: baseline ProcessorFeatureBits = %#x = ours (%#x), same %d flags" % (fexbase, base, len(names)),
              fexbase == base and names == ours and all(int(hdef["HWREG_" + k], 16) == vals[k] for k in vals
                                                       if "HWREG_" + k in hdef))
        check("FEX: SSE4.2 <- leaf1 ECX[20] <- SupportsCRC",
              "if (CPUIDResult01.ecx & (1 << 20)) {\n    CpuInfo.ProcessorFeatureBits |= CPU_FEATURE_SSE42;" in cf
              and "(CTX->HostFeatures.SupportsCRC << 20) |         // SSE4.2" in cpp)
        check("FEX: level/revision formulas and AMD64 for the ARM64EC module",
              "CpuInfo.ProcessorLevel = ((FamilyIdentifier >> 8) & 0xf) + ((FamilyIdentifier >> 20) & 0xff);" in cf
              and "CpuInfo.ProcessorRevision = (FamilyIdentifier & 0xf0000) >> 4;" in cf
              and "CpuInfo.ProcessorRevision |= (FamilyIdentifier & 0xf0) << 4;" in cf
              and "CpuInfo.ProcessorRevision |= FamilyIdentifier & 0xf;" in cf
              and "#ifdef ARCHITECTURE_arm64ec\n  // Report as a 64-bit host for ARM64EC.\n"
                  "  CpuInfo.ProcessorArchitecture = PROCESSOR_ARCHITECTURE_AMD64;" in cf)
        check("FEX: SmallTSCScale (default true) doubles the counter up to TSC_SCALE_MAXIMUM = 1 GHz; leaf 0x15 reports it",
              "while (FrequencyCounter < FEXCore::Context::TSC_SCALE_MAXIMUM) {\n      FrequencyCounter <<= 1;\n"
              "      ++Config.TSCScale;" in core and "TSC_SCALE_MAXIMUM = 1'000'000'000;" in ctx
              and re.search(r'"SmallTSCScale": \{\s*"Type": "bool",\s*"Default": "true"', cfgj) is not None
              and "Res.ebx = 1U << CTX->Config.TSCScale;\n    Res.ecx = FrequencyHz;" in cpp
              and int(hdef["HWREG_TSC_SCALE_MAXIMUM"].rstrip("ul"), 0) == 1000000000)

    # ------------------------------------------------------------ 4. wineboot
    wb_c = wine / "programs/wineboot/wineboot.c"
    sys_c = wine / "dlls/ntdll/unix/system.c"
    if not wb_c.exists() or not sys_c.exists():
        print("note: %s not checked out (set WINE_SRC); wineboot and registry checks skipped" % wb_c)
        print("PASS (partial)" if ok else "FAILED")
        sys.exit(0 if ok else 1)
    wb = wb_c.read_text()
    sysc = sys_c.read_text()
    hw = func(wb, "static void create_hardware_registry_keys(void)")
    pv = func(wb, "static void create_bios_processor_values( HKEY system_key, const char *buf, UINT len )")
    bb = wb[wb.index("static void create_bios_baseboard_values("):wb.index("#ifdef __aarch64__\n\nstatic void create_id_reg_keys_arm64")]
    wb_names = set(re.findall(r'(?:set_value_from_smbios_string|set_reg_value_dword|set_reg_value|RegSetValueExW)\( \w+, L"([^"]+)"',
                              bb + pv))
    our_names = set(re.findall(r'ios_hw_(?:sz|dword)\( key, "([^"]+)"', pub))
    env_names = {"PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION",
                 "NUMBER_OF_PROCESSORS"}
    check("every value wineboot writes in HARDWARE is written, and nothing else (%d names; its five "
          "Session Manager\\Environment values are left to the prefix)" % len(wb_names - env_names),
          wb_names - env_names == our_names and env_names <= wb_names)
    check("wineboot's constants: Identifier 'AT compatible', SystemBiosDate '01/01/70'",
          'set_reg_value( system_key, L"Identifier", L"AT compatible" );' in pv
          and 'set_reg_value( system_key, L"SystemBiosDate", L"01/01/70" );' in pv
          and 'ios_hw_sz( key, "Identifier", "AT compatible" );' in pub and 'ios_hw_sz( key, "SystemBiosDate", "01/01/70" );' in pub)
    check("wineboot's AMD64 Identifier format and Intel64/AMD64 choice",
          'swprintf( id, ARRAY_SIZE(id), L"%s Family %u Model %u Stepping %u",\n'
          '                      vendorid && !wcscmp(vendorid, L"AuthenticAMD") ? L"AMD64" : L"Intel64",\n'
          '                      sci.ProcessorLevel, HIBYTE(sci.ProcessorRevision), LOBYTE(sci.ProcessorRevision) );' in pv
          and '"%s Family %u Model %u Stepping %u"' in header and 'strcmp( cpu->vendor, "AuthenticAMD" ) ? "Intel64" : "AMD64"' in header)
    check("wineboot's keys are all REG_OPTION_VOLATILE (System, BIOS, CentralProcessor, FloatingPointProcessor, N)",
          hw.count("REG_OPTION_VOLATILE") == 2 and pv.count("REG_OPTION_VOLATILE") == 4
          and 'L"Hardware\\\\Description\\\\System"' in hw and 'L"BIOS"' in hw
          and 'L"CentralProcessor"' in pv and 'L"FloatingPointProcessor"' in pv)
    check("wineboot names ~MHz the TSC rate (MaxMhz only when that is 0)",
          "DWORD tsc_freq_mhz = (DWORD)(tsc_frequency / 1000000ull); /* Hz -> Mhz */" in pv
          and "if (!tsc_freq_mhz) tsc_freq_mhz = power_info[core].MaxMhz;" in pv and "if (!cpu.mhz) cpu.mhz = ios_hw_power_mhz();" in pub)
    gen = sysc[sysc.index("#else\n\nstatic struct smbios_prologue *create_smbios_data(void)"):]
    gen = gen[:gen.index("\n}\n") + 3]
    apple = sysc[sysc.index("static struct smbios_prologue *create_smbios_data(void)\n{\n    io_service_t platform_expert;"):]
    apple = apple[:apple.index("\n}\n") + 3]
    check("ntdll's generic table: 'The Wine project' / 'Wine' / PACKAGE_VERSION / 01/01/2021 = our defaults",
          'static const char *vendor  = "The Wine project";' in gen and 'static const char *product = "Wine";' in gen
          and "static const char *version = PACKAGE_VERSION;" in gen
          and 'append_smbios_bios( &buf, vendor, version, "01/01/2021" );' in gen
          and 'append_smbios_system( &buf, vendor, product, version, serial, "", "", &uuid );' in gen
          and "append_smbios_board( &buf, chassis, vendor, product, version, serial, \"\" );" in gen
          and '#define HWREG_WINE_VENDOR   "The Wine project"' in header and '#define HWREG_WINE_PRODUCT  "Wine"' in header
          and '#define HWREG_WINE_DATE     "01/01/2021"' in header
          and "hwreg_bios_values( &bios, smbios, smbios_len, PACKAGE_VERSION );" in pub)
    check("ntdll's Apple table (IOPlatformExpertDevice) as the harness builds it",
          'append_smbios_bios( &buf, manufacturer, "1.0", "01/01/2021" );' in apple
          and 'append_smbios_system( &buf, manufacturer, model, "1.0", serial_number, "", model, &system_uuid );' in apple
          and 'append_smbios_board( &buf, chassis, manufacturer, model, model, serial_number, "" );' in apple)

    sys_structs = sysc[sysc.index("#pragma pack(push,1)"):sysc.index("#define SMBIOS_MINOR_VERSION 0")] + "#define SMBIOS_MINOR_VERSION 0\n"
    sys_append = sysc[sysc.index("struct smbios_buffer\n{"):sysc.index("static void create_smbios_processors(")]
    generator = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "windef.h"
#ifndef max
#define max(a,b) (((a) > (b)) ? (a) : (b))
#endif
#ifndef min
#define min(a,b) (((a) < (b)) ? (a) : (b))
#endif
static ULONGLONG cpu_id = 0x0000000a000661ull;
''' + sys_structs + sys_append + r'''
/* kind: 0 generic (no host data), 1 Apple with manufacturer/model, 2 Apple with
 * nothing readable, 3 SMBIOS 2.3 style short BIOS/system entries, 4 no board. */
unsigned char *gen_table( int kind, unsigned int *len )
{
    struct smbios_buffer buf = { 0 };
    GUID uuid = { 0 };
    WORD chassis;

    if (kind == 0)
    {
        append_smbios_bios( &buf, "The Wine project", "11.4", "01/01/2021" );
        append_smbios_system( &buf, "The Wine project", "Wine", "11.4", "0", "", "", &uuid );
        chassis = append_smbios_chassis( &buf, 0, "The Wine project", "11.4", "0", "" );
        append_smbios_board( &buf, chassis, "The Wine project", "Wine", "11.4", "0", "" );
    }
    else if (kind == 1 || kind == 2)
    {
        const char *m = kind == 1 ? "Apple Inc." : "", *model = kind == 1 ? "iPhone18,2" : "";
        append_smbios_bios( &buf, m, "1.0", "01/01/2021" );
        append_smbios_system( &buf, m, model, "1.0", "", "", model, &uuid );
        chassis = append_smbios_chassis( &buf, 0, m, "", "", "" );
        append_smbios_board( &buf, chassis, m, model, model, "", "" );
    }
    else
    {
        struct smbios_bios bios = { .hdr.type = SMBIOS_TYPE_BIOS, .hdr.length = 0x12 };
        struct smbios_system system = { .hdr.type = SMBIOS_TYPE_SYSTEM, .hdr.length = 0x19 };
        const char *bs[] = { "Old BIOS Co", "2.3", "06/07/2003" }, *ss[] = { "Old PC Co", "Model X", "v1" };
        bios.vendor = 1; bios.version = 2; bios.date = 3;
        bios.system_bios_major_release = 7;   /* beyond the short length: must not be read */
        system.vendor = 1; system.product = 2; system.version = 3;
        system.sku_number = 1; system.family = 2;   /* beyond 0x19: must not be read */
        append_smbios( &buf, &bios.hdr, bs, 3 );
        append_smbios( &buf, &system.hdr, ss, 3 );
        if (kind == 3) append_smbios_board( &buf, 0, "Board Co", "B1", "rev2", "", "" );
    }
    append_smbios_processor( &buf, 6, 6, 0, "Socket #0", "ARM", "", "", "" );
    append_smbios_boot_info( &buf );
    append_smbios_end( &buf );
    *len = sizeof(*buf.prologue) + buf.prologue->length;
    return (unsigned char *)buf.prologue;
}
'''
    wb_structs = wb[wb.index("#pragma pack(push,1)\nstruct smbios_prologue"):wb.index("#pragma pack(pop)") + len("#pragma pack(pop)")]
    wb_funcs = wb[wb.index("static const struct smbios_header *find_smbios_entry("):wb.index("#ifdef __aarch64__\n\nstatic void create_id_reg_keys_arm64")]
    wineboot = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "windef.h"
#include "winbase.h"
#include "winnls.h"
#define WARN(...) do { } while (0)
static char rec[4096];
static void narrow( const WCHAR *w, char *out ) { while ((*out++ = (char)*w++)) ; }
static DWORD set_reg_value( HKEY hkey, const WCHAR *name, const WCHAR *value )
{
    char n[64], v[256];
    narrow( name, n ); narrow( value, v );
    sprintf( rec + strlen( rec ), "%s=sz:%s;", n, v );
    return 0;
}
static DWORD set_reg_value_dword( HKEY hkey, const WCHAR *name, DWORD value )
{
    char n[64];
    narrow( name, n );
    sprintf( rec + strlen( rec ), "%s=dword:0x%08x;", n, (unsigned)value );
    return 0;
}
INT WINAPI MultiByteToWideChar( UINT cp, DWORD flags, LPCSTR src, INT srclen, LPWSTR dst, INT dstlen )
{
    INT i, n = srclen < 0 ? (INT)strlen( src ) + 1 : srclen;
    if (!dst) return n;
    for (i = 0; i < n && i < dstlen; i++) dst[i] = (unsigned char)src[i];
    return i;
}
''' + wb_structs + "\n#define RSMB (('R' << 24) | ('S' << 16) | ('M' << 8) | 'B')\n" + wb_funcs + r'''
void wb_record( const unsigned char *buf, unsigned int len, char *out )
{
    rec[0] = 0;
    create_bios_baseboard_values( NULL, (const char *)buf, len );
    create_bios_bios_values( NULL, (const char *)buf, len );
    create_bios_system_values( NULL, (const char *)buf, len );
    strcpy( out, rec );
}
long wb_find( int type, int index, const unsigned char *buf, unsigned int len )
{
    const struct smbios_header *h = find_smbios_entry( type, index, (const char *)buf, len );
    return h ? (long)((const unsigned char *)h - buf) : -1;
}
'''
    ours = r'''
#include "hw_registry_ios.h"
void hw_record( const unsigned char *buf, unsigned int len, char *out, unsigned int *found, unsigned int *defaults )
{
    struct hwreg_bios b;
    hwreg_bios_values( &b, buf, len, "11.4" );
    sprintf( out, "BaseBoardManufacturer=sz:%s;BaseBoardProduct=sz:%s;BaseBoardVersion=sz:%s;"
             "BIOSVendor=sz:%s;BIOSVersion=sz:%s;BIOSReleaseDate=sz:%s;BiosMajorRelease=dword:0x%08x;"
             "BiosMinorRelease=dword:0x%08x;ECFirmwareMajorVersion=dword:0x%08x;ECFirmwareMinorVersion=dword:0x%08x;"
             "SystemManufacturer=sz:%s;SystemProductName=sz:%s;SystemVersion=sz:%s;SystemSKU=sz:%s;SystemFamily=sz:%s;",
             b.board_vendor, b.board_product, b.board_version, b.bios_vendor, b.bios_version, b.bios_date,
             b.bios_major, b.bios_minor, b.ec_major, b.ec_minor, b.sys_vendor, b.sys_product, b.sys_version,
             b.sys_sku, b.sys_family );
    *found = b.found;
    *defaults = b.defaults;
}
long hw_find( int type, int index, const unsigned char *buf, unsigned int len )
{
    const unsigned char *h = hwreg_smbios_entry( type, index, buf, len );
    return h ? (long)(h - buf) : -1;
}
'''
    compare = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
unsigned char *gen_table( int kind, unsigned int *len );
void wb_record( const unsigned char *buf, unsigned int len, char *out );
long wb_find( int type, int index, const unsigned char *buf, unsigned int len );
void hw_record( const unsigned char *buf, unsigned int len, char *out, unsigned int *found, unsigned int *defaults );
long hw_find( int type, int index, const unsigned char *buf, unsigned int len );
int main( void )
{
    static const int types[] = { 0, 1, 2, 3, 4, 32, 44, 127 };
    char a[4096], b[4096];
    unsigned int len, found, defaults, i, j;
    int kind;
    for (kind = 0; kind <= 4; kind++)
    {
        unsigned char *t = gen_table( kind, &len );
        int same = 1;
        for (i = 0; i < sizeof(types) / sizeof(types[0]); i++)
            for (j = 0; j < 3; j++)
                if (wb_find( types[i], j, t, len ) != hw_find( types[i], j, t, len )) same = 0;
        wb_record( t, len, a );
        hw_record( t, len, b, &found, &defaults );
        printf( "kind%d entries %s found %u defaults %u\nwb  %s\nour %s\n", kind, same ? "same" : "DIFFER",
                found, defaults, a, b );
        free( t );
    }
    hw_record( NULL, 0, b, &found, &defaults );
    printf( "none found %u defaults %u\nour %s\n", found, defaults, b );
    return 0;
}
'''
    flags = ["-fshort-wchar", "-D__WINESRC__", "-DWINE_UNIX_LIB", "-I", str(wine / "include"),
             "-Wno-unused-variable", "-Wno-pointer-sign", "-Wno-unknown-pragmas"]
    out = run_c({"gen.c": generator, "wb.c": wineboot, "ours.c": ours, "cmp.c": compare}, tmp / "cmp", flags)
    check("wineboot's parser, ntdll's generator and hw_registry_ios.h compile together and run", out is not None)
    out = out or ""
    blocks = dict((m.group(1), m.group(0)) for m in re.finditer(r"(kind\d|none)[^\n]*\n(?:wb  [^\n]*\n)?our [^\n]*\n", out))

    def recs(kind):
        bl = blocks.get(kind, "")
        wbr = re.search(r"\nwb  ([^\n]*)", bl)
        our = re.search(r"\nour ([^\n]*)", bl)
        return (wbr.group(1) if wbr else None), (our.group(1) if our else None), bl

    a, b, bl = recs("kind0")
    check("generic Wine table: entries found at the same offsets, values identical to wineboot's",
          "entries same found 7 defaults 0" in bl and a == b and "BIOSVersion=sz:11.4;" in (b or ""))
    a, b, bl = recs("kind1")
    check("Apple table (Apple Inc. / iPhone18,2): identical to wineboot's, no defaults",
          "entries same found 7 defaults 0" in bl and a == b
          and "SystemProductName=sz:iPhone18,2;SystemVersion=sz:1.0;SystemSKU=sz:;SystemFamily=sz:iPhone18,2;" in (b or ""))
    a, b, bl = recs("kind2")
    diff = [(x, y) for x, y in zip((a or "").split(";"), (b or "").split(";")) if x != y]
    check("Apple table with nothing readable: wineboot's empty strings become Wine's values, nothing else differs (%s)" % diff,
          "entries same found 7" in bl and diff == [
              ("BaseBoardManufacturer=sz:", "BaseBoardManufacturer=sz:The Wine project"),
              ("BaseBoardProduct=sz:", "BaseBoardProduct=sz:Wine"),
              ("BaseBoardVersion=sz:", "BaseBoardVersion=sz:11.4"),
              ("BIOSVendor=sz:", "BIOSVendor=sz:The Wine project"),
              ("SystemManufacturer=sz:", "SystemManufacturer=sz:The Wine project"),
              ("SystemProductName=sz:", "SystemProductName=sz:Wine")])
    a, b, bl = recs("kind3")
    check("SMBIOS 2.3 style entries: releases 0xff, SKU/family empty -- as wineboot",
          "entries same found 7 defaults 0" in bl and a == b and "BiosMajorRelease=dword:0x000000ff;" in (b or "")
          and "SystemSKU=sz:;SystemFamily=sz:;" in (b or "") and "BaseBoardVersion=sz:rev2;" in (b or ""))
    a, b, bl = recs("kind4")
    check("no baseboard entry: wineboot writes no BaseBoard values, we write Wine's",
          "entries same found 3 defaults 3" in bl and "BaseBoard" not in (a or "x")
          and (b or "").startswith("BaseBoardManufacturer=sz:The Wine project;BaseBoardProduct=sz:Wine;BaseBoardVersion=sz:11.4;")
          and (b or "").split("BaseBoardVersion=sz:11.4;")[-1] == a)
    a, b, bl = recs("none")
    check("no SMBIOS table at all: Wine's generic values, releases 0xff",
          "none found 0 defaults 9" in bl and b == "BaseBoardManufacturer=sz:The Wine project;BaseBoardProduct=sz:Wine;"
          "BaseBoardVersion=sz:11.4;BIOSVendor=sz:The Wine project;BIOSVersion=sz:11.4;BIOSReleaseDate=sz:01/01/2021;"
          "BiosMajorRelease=dword:0x000000ff;BiosMinorRelease=dword:0x000000ff;ECFirmwareMajorVersion=dword:0x000000ff;"
          "ECFirmwareMinorVersion=dword:0x000000ff;SystemManufacturer=sz:The Wine project;SystemProductName=sz:Wine;"
          "SystemVersion=sz:11.4;SystemSKU=sz:;SystemFamily=sz:;")

    # fuzz: truncated and mutated tables through our parser, with sanitizers when available
    fuzz = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "hw_registry_ios.h"
unsigned char *gen_table( int kind, unsigned int *len );
int main( void )
{
    unsigned int len, i, n, runs = 0;
    int kind;
    srand( 1 );
    for (kind = 0; kind <= 4; kind++)
    {
        unsigned char *t = gen_table( kind, &len );
        for (n = 0; n <= len; n++)   /* every truncation, in an exactly sized copy */
        {
            unsigned char *c = malloc( n ? n : 1 );
            struct hwreg_bios b;
            memcpy( c, t, n );
            hwreg_bios_values( &b, c, n, "11.4" );
            free( c );
            runs++;
        }
        for (i = 0; i < 20000; i++)  /* random byte flips */
        {
            unsigned char *c = malloc( len );
            struct hwreg_bios b;
            unsigned int k, flips = 1 + rand() % 4;
            memcpy( c, t, len );
            for (k = 0; k < flips; k++) c[rand() % len] = (unsigned char)rand();
            hwreg_bios_values( &b, c, len, "11.4" );
            if (strlen( b.bios_vendor ) >= HWREG_STR || strlen( b.sys_family ) >= HWREG_STR) return 1;
            free( c );
            runs++;
        }
        free( t );
    }
    printf( "fuzz %u runs\n", runs );
    return 0;
}
'''
    san = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
    probe = subprocess.run([CC, "-x", "c", "-", "-o", str(tmp / "probe")] + san, input="int main(void){return 0;}",
                           capture_output=True, text=True)
    use = san if probe.returncode == 0 else []
    out = run_c({"gen2.c": generator, "fuzz.c": fuzz}, tmp / "fuzz", flags + use)
    check("parser fuzz: every truncation and 100000 mutated tables%s" % (" under ASan/UBSan" if use else " (no sanitizers here)"),
          out is not None and "fuzz" in out)

    # ------------------------------------------------------------ 5. publish against a fake registry
    harness = r'''
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
#include "hw_registry_ios.h"

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif
#define PACKAGE_VERSION "11.4"

/* unix_private.h's helpers. */
static inline void ascii_to_unicode( WCHAR *dst, const char *src, size_t len )
{
    while (len--) *dst++ = (unsigned char)*src++;
}
static inline void init_unicode_string( UNICODE_STRING *str, const WCHAR *data )
{
    const WCHAR *p = data;
    while (*p) p++;
    str->Length = (p - data) * sizeof(WCHAR);
    str->MaximumLength = str->Length + sizeof(WCHAR);
    str->Buffer = (WCHAR *)data;
}

static PEB fake_peb;
PEB *peb = &fake_peb;

struct value { char name[64]; ULONG type; ULONG size; unsigned char data[600]; };
struct node { char name[160]; struct node *parent; int is_volatile; unsigned int nvalues; struct value values[24]; };
static struct node nodes[96];
static unsigned int node_count, creates, sets, log_lines, open_handles;
static char last_log[1024];
static struct node *root_node;

static void narrow( const UNICODE_STRING *s, char *out )
{
    unsigned int i, n = s->Length / sizeof(WCHAR);
    for (i = 0; i < n; i++) out[i] = (char)s->Buffer[i];
    out[n] = 0;
}
static struct node *child( struct node *parent, const char *name )
{
    unsigned int i;
    for (i = 0; i < node_count; i++)
        if (nodes[i].parent == parent && !strcasecmp( nodes[i].name, name )) return &nodes[i];
    return NULL;
}
static struct node *add( struct node *parent, const char *name, int vol )
{
    struct node *n = &nodes[node_count++];
    assert( node_count < ARRAY_SIZE(nodes) );
    memset( n, 0, sizeof(*n) );
    strcpy( n->name, name );
    n->parent = parent;
    n->is_volatile = vol;
    return n;
}
static struct node *walk( struct node *n, char *path, char **rest )
{
    char *p = path, *e;
    while (*p == '\\') p++;
    while (*p)
    {
        struct node *c;
        if ((e = strchr( p, '\\' ))) *e = 0;
        if (!(c = child( n, p ))) { if (e) *e = '\\'; *rest = p; return n; }
        n = c;
        if (!e) break;
        p = e + 1;
    }
    *rest = NULL;
    return n;
}
NTSTATUS WINAPI NtOpenKey( HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr )
{
    char path[512], *rest;
    struct node *n;
    narrow( attr->ObjectName, path );
    n = walk( attr->RootDirectory ? (struct node *)attr->RootDirectory : root_node, path, &rest );
    if (rest) return STATUS_OBJECT_NAME_NOT_FOUND;
    *key = n;
    open_handles++;
    return STATUS_SUCCESS;
}
/* Wine 11: NtCreateKey makes ONE key and fails when a parent is missing. */
NTSTATUS WINAPI NtCreateKey( HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG index,
                             const UNICODE_STRING *class, ULONG options, ULONG *dispos )
{
    char path[512], *rest;
    struct node *n;
    narrow( attr->ObjectName, path );
    n = walk( attr->RootDirectory ? (struct node *)attr->RootDirectory : root_node, path, &rest );
    if (rest)
    {
        if (strchr( rest, '\\' )) return STATUS_OBJECT_NAME_NOT_FOUND;
        if (n->is_volatile && !(options & REG_OPTION_VOLATILE)) return STATUS_CHILD_MUST_BE_VOLATILE;
        n = add( n, rest, !!(options & REG_OPTION_VOLATILE) );
        creates++;
    }
    *key = n;
    open_handles++;
    return STATUS_SUCCESS;
}
static struct value *find_value( struct node *n, const char *name )
{
    unsigned int i;
    for (i = 0; i < n->nvalues; i++) if (!strcasecmp( n->values[i].name, name )) return &n->values[i];
    return NULL;
}
NTSTATUS WINAPI NtSetValueKey( HANDLE key, const UNICODE_STRING *name, ULONG index, ULONG type,
                               const void *data, ULONG size )
{
    struct node *n = key;
    struct value *v;
    char vname[64];
    narrow( name, vname );
    assert( size <= sizeof(v->data) );
    if (type == REG_SZ)
        assert( size % sizeof(WCHAR) == 0 && size >= sizeof(WCHAR) && !((const WCHAR *)data)[size / sizeof(WCHAR) - 1] );
    if (type == REG_DWORD) assert( size == sizeof(DWORD) );
    if (!(v = find_value( n, vname )))
    {
        assert( n->nvalues < ARRAY_SIZE(n->values) );
        v = &n->values[n->nvalues++];
        strcpy( v->name, vname );
    }
    v->type = type;
    v->size = size;
    memcpy( v->data, data, size );
    sets++;
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtQueryValueKey( HANDLE key, const UNICODE_STRING *name, KEY_VALUE_INFORMATION_CLASS class,
                                 void *info, DWORD length, DWORD *result_len )
{
    struct node *n = key;
    KEY_VALUE_PARTIAL_INFORMATION *p = info;
    struct value *v;
    char vname[64];
    narrow( name, vname );
    assert( class == KeyValuePartialInformation );
    if (!(v = find_value( n, vname ))) return STATUS_OBJECT_NAME_NOT_FOUND;
    *result_len = offsetof( KEY_VALUE_PARTIAL_INFORMATION, Data ) + v->size;
    if (length < *result_len) return STATUS_BUFFER_OVERFLOW;
    p->TitleIndex = 0;
    p->Type = v->type;
    p->DataLength = v->size;
    memcpy( p->Data, v->data, v->size );
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtClose( HANDLE handle ) { assert( open_handles ); open_handles--; return STATUS_SUCCESS; }

/* GetSystemFirmwareTable('RSMB') as ntdll's get_firmware_info answers it. */
unsigned char *gen_table( int kind, unsigned int *len );
static int table_kind = 1;   /* -1: create_smbios_data failed */
static unsigned int fw_queries;
NTSTATUS WINAPI NtQuerySystemInformation( SYSTEM_INFORMATION_CLASS class, void *info, ULONG size, ULONG *ret_size )
{
    SYSTEM_FIRMWARE_TABLE_INFORMATION *sfti = info;
    unsigned int len;
    ULONG need;
    unsigned char *t;
    assert( class == SystemFirmwareTableInformation );
    assert( size >= offsetof( SYSTEM_FIRMWARE_TABLE_INFORMATION, TableBuffer ) );
    assert( sfti->ProviderSignature == 0x52534d42 && sfti->Action == SystemFirmwareTable_Get && !sfti->TableID );
    fw_queries++;
    if (ret_size) *ret_size = 0;
    if (table_kind < 0) return STATUS_NO_MEMORY;
    t = gen_table( table_kind, &len );
    sfti->TableBufferLength = len;
    need = offsetof( SYSTEM_FIRMWARE_TABLE_INFORMATION, TableBuffer[len] );
    if (ret_size) *ret_size = need;
    if (size < need) { free( t ); return STATUS_BUFFER_TOO_SMALL; }
    memcpy( sfti->TableBuffer, t, len );
    free( t );
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtPowerInformation( POWER_INFORMATION_LEVEL level, void *in, ULONG in_size, void *out, ULONG out_size )
{
    PROCESSOR_POWER_INFORMATION *p = out;
    ULONG i;
    assert( level == ProcessorInformation );
    if (out_size / sizeof(*p) < peb->NumberOfProcessors) return STATUS_BUFFER_TOO_SMALL;
    for (i = 0; i < peb->NumberOfProcessors; i++) { p[i].Number = i; p[i].MaxMhz = p[i].CurrentMhz = 1000; }
    return STATUS_SUCCESS;
}
static uint64_t fake_cntfrq = 24000000;
static uint64_t ios_hw_cntfrq( void ) { return fake_cntfrq; }
/* server_ios.c declares it with the same format check */
static void wine_log_write( const char *fmt, ... ) __attribute__((format(printf, 1, 2)));
static void wine_log_write( const char *fmt, ... )
{
    va_list args;
    va_start( args, fmt );
    vsnprintf( last_log, sizeof(last_log), fmt, args );
    va_end( args );
    log_lines++;
}
''' + region + r'''

static struct node *find( const char *path )
{
    char copy[512], *rest;
    struct node *n;
    strcpy( copy, path );
    n = walk( root_node, copy, &rest );
    return rest ? NULL : n;
}
static const char *vals( const char *path )
{
    static char out[4096];
    struct node *n = find( path );
    unsigned int i, k;
    out[0] = 0;
    if (!n) return "(missing)";
    for (i = 0; i < n->nvalues; i++)
    {
        struct value *v = &n->values[i];
        char *o = out + strlen( out );
        if (v->type == REG_DWORD) sprintf( o, "%s=dword:0x%08x;", v->name, *(DWORD *)v->data );
        else
        {
            o += sprintf( o, "%s=%s:", v->name, v->type == REG_SZ ? "sz" : "?" );
            for (k = 0; k + 1 < v->size / sizeof(WCHAR); k++) *o++ = (char)((WCHAR *)v->data)[k];
            *o++ = ';';
            *o = 0;
        }
    }
    return out;
}
static void set_env( struct node *env, const char *name, const char *value )
{
    WCHAR nameW[64], data[128];
    UNICODE_STRING str;
    ascii_to_unicode( nameW, name, strlen( name ) + 1 );
    ascii_to_unicode( data, value, strlen( value ) + 1 );
    init_unicode_string( &str, nameW );
    NtSetValueKey( env, &str, 0, REG_SZ, data, (strlen( value ) + 1) * sizeof(WCHAR) );
}
static struct node *env_node;
static void reset( unsigned int cpus )
{
    struct node *m;
    node_count = creates = sets = log_lines = fw_queries = open_handles = 0;
    last_log[0] = 0;
    root_node = add( NULL, "", 0 );
    m = add( add( root_node, "Registry", 0 ), "Machine", 0 );
    add( m, "Software", 0 );
    env_node = add( add( add( add( add( m, "System", 0 ), "CurrentControlSet", 0 ), "Control", 0 ), "Session Manager", 0 ),
                    "Environment", 0 );
    /* the prefix template's values (written by wineboot on the machine that built it) */
    set_env( env_node, "NUMBER_OF_PROCESSORS", "16" );
    set_env( env_node, "OS", "Windows_NT" );
    set_env( env_node, "PROCESSOR_ARCHITECTURE", "AMD64" );
    set_env( env_node, "PROCESSOR_IDENTIFIER", "Intel64 Family 6 Model 44 Stepping 0, GenuineIntel" );
    set_env( env_node, "PROCESSOR_LEVEL", "6" );
    set_env( env_node, "PROCESSOR_REVISION", "2c00" );
    sets = 0;
    fake_peb.NumberOfProcessors = cpus;
    fake_cntfrq = 24000000;
    table_kind = 1;
    unsetenv( "MADEIRA_HW_REGISTRY" );
}
#define SYS "\\Registry\\Machine\\HARDWARE\\DESCRIPTION\\System"
#define CPU0 "FeatureSet=dword:0x2379ffff;Identifier=sz:Intel64 Family 6 Model 166 Stepping 1;" \
             "VendorIdentifier=sz:GenuineIntel;ProcessorNameString=sz:Unknown ARM CPU;~MHz=dword:0x00000600;"
#define ENVSTART "NUMBER_OF_PROCESSORS=sz:16;OS=sz:Windows_NT;PROCESSOR_ARCHITECTURE=sz:AMD64;" \
                 "PROCESSOR_IDENTIFIER=sz:Intel64 Family 6 Model 44 Stepping 0, GenuineIntel;PROCESSOR_LEVEL=sz:6;" \
                 "PROCESSOR_REVISION=sz:2c00;"

int main( void )
{
    char path[256];
    unsigned int i, first_creates;
    struct node *n;

    /* default: six processors, the Apple table */
    reset( 6 );
    ios_hw_registry_publish();
    assert( !open_handles );
    n = find( "\\Registry\\Machine\\HARDWARE" );
    assert( n && n->is_volatile && find( "\\Registry\\Machine\\HARDWARE\\DESCRIPTION" )->is_volatile );
    assert( find( SYS )->is_volatile && find( SYS "\\BIOS" )->is_volatile );
    assert( find( SYS "\\CentralProcessor" )->is_volatile && find( SYS "\\FloatingPointProcessor" )->is_volatile );
    assert( !strcmp( vals( SYS ), "Identifier=sz:AT compatible;SystemBiosDate=sz:01/01/70;" ) );
    for (i = 0; i < 6; i++)
    {
        sprintf( path, SYS "\\CentralProcessor\\%u", i );
        assert( find( path ) && find( path )->is_volatile && !strcmp( vals( path ), CPU0 ) );
        sprintf( path, SYS "\\FloatingPointProcessor\\%u", i );
        assert( find( path ) && find( path )->is_volatile &&
                !strcmp( vals( path ), "Identifier=sz:Intel64 Family 6 Model 166 Stepping 1;" ) );
    }
    assert( !find( SYS "\\CentralProcessor\\6" ) && !find( SYS "\\FloatingPointProcessor\\6" ) );
    assert( !strcmp( vals( SYS "\\BIOS" ),
        "BaseBoardManufacturer=sz:Apple Inc.;BaseBoardProduct=sz:iPhone18,2;BaseBoardVersion=sz:iPhone18,2;"
        "BIOSVendor=sz:Apple Inc.;BIOSVersion=sz:1.0;BIOSReleaseDate=sz:01/01/2021;BiosMajorRelease=dword:0x000000ff;"
        "BiosMinorRelease=dword:0x000000ff;ECFirmwareMajorVersion=dword:0x000000ff;ECFirmwareMinorVersion=dword:0x000000ff;"
        "SystemManufacturer=sz:Apple Inc.;SystemProductName=sz:iPhone18,2;SystemVersion=sz:1.0;SystemSKU=sz:;"
        "SystemFamily=sz:iPhone18,2;" ) );
    assert( !strcmp( vals( "\\Registry\\Machine\\System\\CurrentControlSet\\Control\\Session Manager\\Environment" ), ENVSTART ) );
    assert( fw_queries == 2 && log_lines == 1 );
    assert( !strcmp( last_log, "[hw-registry] HKLM\\HARDWARE\\DESCRIPTION\\System (volatile): 6/6 CentralProcessor "
                               "+ 6 FloatingPointProcessor \"Intel64 Family 6 Model 166 Stepping 1\" GenuineIntel "
                               "\"Unknown ARM CPU\" ~MHz 1536 FeatureSet 0x2379ffff; BIOS \"Apple Inc.\" \"iPhone18,2\" "
                               "(SMBIOS, 0 Wine default(s))" ) );
    printf( "default: %u keys, %u values, line: %s\n", creates, sets, last_log );
    first_creates = creates;

    /* the next session in the same wineserver: same keys, nothing new */
    creates = sets = log_lines = 0;
    ios_hw_registry_publish();
    assert( !creates && log_lines == 1 && !strcmp( vals( SYS "\\CentralProcessor\\5" ), CPU0 ) && !open_handles );
    assert( first_creates == 3 + 1 + 1 + 6 + 1 + 6 );

    /* off */
    reset( 6 );
    setenv( "MADEIRA_HW_REGISTRY", "0", 1 );
    ios_hw_registry_publish();
    assert( !creates && !sets && !fw_queries && log_lines == 1 && strstr( last_log, "MADEIRA_HW_REGISTRY=0, no" ) );
    assert( !find( "\\Registry\\Machine\\HARDWARE" ) );

    /* no SMBIOS table, no counter frequency, one processor */
    reset( 1 );
    table_kind = -1;
    fake_cntfrq = 0;
    ios_hw_registry_publish();
    assert( !strcmp( vals( SYS "\\CentralProcessor\\0" ),
        "FeatureSet=dword:0x2379ffff;Identifier=sz:Intel64 Family 6 Model 166 Stepping 1;VendorIdentifier=sz:GenuineIntel;"
        "ProcessorNameString=sz:Unknown ARM CPU;~MHz=dword:0x000003e8;" ) );
    assert( !find( SYS "\\CentralProcessor\\1" ) && fw_queries == 1 );
    assert( strstr( vals( SYS "\\BIOS" ), "BIOSVendor=sz:The Wine project;BIOSVersion=sz:11.4;BIOSReleaseDate=sz:01/01/2021;" ) );
    assert( strstr( vals( SYS "\\BIOS" ), "SystemManufacturer=sz:The Wine project;SystemProductName=sz:Wine;SystemVersion=sz:11.4;" ) );
    assert( strstr( last_log, "1/1 CentralProcessor" ) && strstr( last_log, "FeatureSet 0x2379ffff" )
            && strstr( last_log, "~MHz 1000" ) && strstr( last_log, "(no SMBIOS table, 9 Wine default(s))" ) );
    printf( "fallbacks: %s\n", last_log );

    /* a processor count of 0 still gives one key; HARDWARE already there (win32u's DEVICEMAP) */
    reset( 0 );
    add( add( add( find( "\\Registry\\Machine" ), "HARDWARE", 1 ), "DEVICEMAP", 1 ), "VIDEO", 1 );
    ios_hw_registry_publish();
    assert( find( SYS "\\CentralProcessor\\0" ) && !find( SYS "\\CentralProcessor\\1" ) );
    assert( find( "\\Registry\\Machine\\HARDWARE\\DEVICEMAP\\VIDEO" ) && strstr( last_log, "1/1 CentralProcessor" ) );

    /* the generic Wine table */
    reset( 6 );
    table_kind = 0;
    ios_hw_registry_publish();
    assert( strstr( vals( SYS "\\BIOS" ), "SystemManufacturer=sz:The Wine project;SystemProductName=sz:Wine;"
                                          "SystemVersion=sz:11.4;SystemSKU=sz:;SystemFamily=sz:;" ) );
    assert( strstr( last_log, "BIOS \"The Wine project\" \"Wine\" (SMBIOS, 0 Wine default(s))" ) );
    puts( "registry: all scenarios passed" );
    return 0;
}
'''
    out = run_c({"gen3.c": generator, "registry.c": harness}, tmp / "registry",
                flags + ["-Werror", "-Wno-unused-but-set-variable"] + use)
    check("publish region compiles warning-free (-Werror) against Wine's headers", out is not None)
    print("     " + (out or "").replace("\n", "\n     ").rstrip())
    check("fake registry: keys volatile, values, idempotent rerun, off, no SMBIOS, zero counter, "
          "count 0, existing HARDWARE, Environment untouched, generic table",
          out is not None and "registry: all scenarios passed" in out)

    # the counter read itself, for an aarch64 target when the host compiler can
    cnt = func(server, "static uint64_t ios_hw_cntfrq(void)")
    src = tmp / "cntfrq.c"
    src.write_text("#include <stdint.h>\n" + cnt + "uint64_t f(void) { return ios_hw_cntfrq(); }\n")
    clang = shutil.which("clang")
    if clang:
        r = subprocess.run([clang, "--target=aarch64-linux-gnu", "-ffreestanding", "-O1", "-c", str(src), "-o",
                            str(tmp / "cntfrq.o")], capture_output=True, text=True)
        check("ios_hw_cntfrq's mrs CNTFRQ_EL0 assembles for aarch64", r.returncode == 0)
        if r.returncode:
            print(r.stderr[-1500:])
    else:
        print("note: no clang; the aarch64 assembly of ios_hw_cntfrq is not checked")

print("PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
