/*
 * The values of the volatile hardware description keys
 * (HKLM\HARDWARE\DESCRIPTION\System) that wineboot writes at every boot on
 * desktop Wine -- programs/wineboot/wineboot.c create_hardware_registry_keys,
 * create_bios_*_values and create_bios_processor_values. wineboot never runs
 * on iOS (env_ios.c: no fork/exec), so no session had these keys.
 *
 * Only the value building lives here: plain C, no Wine headers, so that
 * tests/host/check-hw-registry.py compiles it on a host and compares it with
 * wineboot's own SMBIOS parser and with FEX's CPUID source.
 * build/ntdll-unix/server_ios.c (ios_hw_registry_publish) writes the keys.
 *
 * The processor values describe the CPU the x86-64 guest sees, i.e. FEX's
 * CPUID on this port, not the ARM host: the guest's GetSystemInfo reports what
 * FEX's UpdateProcessorInformation fills in (AMD64, family 6, revision
 * 0xA601), and stock wineboot builds the same values from the same
 * SYSTEM_CPU_INFORMATION and the SMBIOS processor strings.
 */
#ifndef MADEIRA_HW_REGISTRY_IOS_H
#define MADEIRA_HW_REGISTRY_IOS_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define HWREG_STR       128   /* longest string value written, terminator included */
#define HWREG_MAX_CPUS  64    /* MAXIMUM_PROCESSORS on 64-bit Windows */

/* FEX's CPUID answers (FEXCore/Source/Interface/Core/CPUID.cpp, CPUID_AMD not
 * defined): leaf 1 EAX = FAMILY_IDENTIFIER, leaf 0 / 0x80000000 vendor
 * "GenuineIntel", leaves 0x80000002-4 the PerCPUData ProductName. The iOS
 * branch of FEX::Windows::CPUFeatures::FetchHostFeatures publishes ONE MIDR, 0,
 * which the CPUMIDRs table maps to ARM_UNKNOWN for every core.
 * check-hw-registry.py reads these back out of the FEX sources. */
#define HWREG_FEX_STEPPING    1
#define HWREG_FEX_MODEL       6
#define HWREG_FEX_EXT_MODEL   0xA
#define HWREG_FEX_FAMILY      6
#define HWREG_FEX_EXT_FAMILY  0
#define HWREG_FEX_VENDOR      "GenuineIntel"
#define HWREG_FEX_BRAND       "Unknown ARM CPU"

/* FEXCore::Context::TSC_SCALE_MAXIMUM; SmallTSCScale (default on) doubles a
 * slower cycle counter until it reaches this (FEXCore Core.cpp), and CPUID
 * 0x15 reports CNTFRQ_EL0 << TSCScale as the TSC rate. */
#define HWREG_TSC_SCALE_MAXIMUM 1000000000ull

/* CPU_FEATURE_* as FEX's Source/Windows/include/winternl.h numbers them. */
#define HWREG_CPU_FEATURE_VME    0x00000005u
#define HWREG_CPU_FEATURE_TSC    0x00000002u
#define HWREG_CPU_FEATURE_CMOV   0x00000008u
#define HWREG_CPU_FEATURE_PGE    0x00000014u
#define HWREG_CPU_FEATURE_PSE    0x00000024u
#define HWREG_CPU_FEATURE_MTRR   0x00000040u
#define HWREG_CPU_FEATURE_CX8    0x00000080u
#define HWREG_CPU_FEATURE_MMX    0x00000100u
#define HWREG_CPU_FEATURE_X86    0x00000200u
#define HWREG_CPU_FEATURE_PAT    0x00000400u
#define HWREG_CPU_FEATURE_FXSR   0x00000800u
#define HWREG_CPU_FEATURE_SEP    0x00001000u
#define HWREG_CPU_FEATURE_SSE    0x00002000u
#define HWREG_CPU_FEATURE_3DNOW  0x00004000u
#define HWREG_CPU_FEATURE_SSE2   0x00010000u
#define HWREG_CPU_FEATURE_SSE3   0x00080000u
#define HWREG_CPU_FEATURE_CX128  0x00100000u
#define HWREG_CPU_FEATURE_NX     0x20000000u
#define HWREG_CPU_FEATURE_SSSE3  0x00008000u
#define HWREG_CPU_FEATURE_SSE41  0x01000000u
#define HWREG_CPU_FEATURE_SSE42  0x02000000u
#define HWREG_CPU_FEATURE_PAE    0x00200000u
#define HWREG_CPU_FEATURE_DAZ    0x00400000u

/* FEX's CPUFeatures constructor: the baseline ProcessorFeatureBits, in its order. */
#define HWREG_FEX_FEATURES (HWREG_CPU_FEATURE_VME | HWREG_CPU_FEATURE_TSC | HWREG_CPU_FEATURE_CMOV | \
    HWREG_CPU_FEATURE_PGE | HWREG_CPU_FEATURE_PSE | HWREG_CPU_FEATURE_MTRR | HWREG_CPU_FEATURE_CX8 | \
    HWREG_CPU_FEATURE_MMX | HWREG_CPU_FEATURE_X86 | HWREG_CPU_FEATURE_PAT | HWREG_CPU_FEATURE_FXSR | \
    HWREG_CPU_FEATURE_SEP | HWREG_CPU_FEATURE_SSE | HWREG_CPU_FEATURE_3DNOW | HWREG_CPU_FEATURE_SSE2 | \
    HWREG_CPU_FEATURE_SSE3 | HWREG_CPU_FEATURE_CX128 | HWREG_CPU_FEATURE_NX | HWREG_CPU_FEATURE_SSSE3 | \
    HWREG_CPU_FEATURE_SSE41 | HWREG_CPU_FEATURE_PAE | HWREG_CPU_FEATURE_DAZ)

/* What ntdll's create_smbios_data puts in the table when it knows nothing
 * about the host (wine/dlls/ntdll/unix/system.c, the generic branch); used
 * for every BIOS/system/board string the host table lacks or leaves empty. */
#define HWREG_WINE_VENDOR   "The Wine project"
#define HWREG_WINE_PRODUCT  "Wine"
#define HWREG_WINE_DATE     "01/01/2021"

#define HWREG_SMBIOS_BIOS      0
#define HWREG_SMBIOS_SYSTEM    1
#define HWREG_SMBIOS_BASEBOARD 2

/* The SMBIOS entries the table had (struct hwreg_bios.found). */
#define HWREG_FOUND_BIOS   1
#define HWREG_FOUND_SYSTEM 2
#define HWREG_FOUND_BOARD  4

struct hwreg_cpu
{
    char vendor[13];          /* VendorIdentifier: the CPUID vendor */
    char brand[49];           /* ProcessorNameString: the CPUID brand string */
    char identifier[64];      /* Identifier: wineboot's AMD64 format */
    unsigned int level;       /* SYSTEM_CPU_INFORMATION.ProcessorLevel (family) */
    unsigned int revision;    /* ProcessorRevision: model << 8 | stepping */
    uint32_t feature_set;     /* FeatureSet: ProcessorFeatureBits as FEX reports them */
    uint32_t mhz;             /* ~MHz: the guest's TSC rate, 0 = unknown */
};

struct hwreg_bios
{
    char bios_vendor[HWREG_STR], bios_version[HWREG_STR], bios_date[HWREG_STR];
    unsigned int bios_major, bios_minor, ec_major, ec_minor;
    char sys_vendor[HWREG_STR], sys_product[HWREG_STR], sys_version[HWREG_STR];
    char sys_sku[HWREG_STR], sys_family[HWREG_STR];
    char board_vendor[HWREG_STR], board_product[HWREG_STR], board_version[HWREG_STR];
    unsigned int found;       /* HWREG_FOUND_*: entries the SMBIOS table had */
    unsigned int defaults;    /* strings taken from Wine's generic table */
};

/* MADEIRA_HW_REGISTRY: 0 writes nothing; unset or anything else writes the keys. */
static inline int hwreg_enabled( const char *env )
{
    return !(env && env[0] == '0');
}

/* One CentralProcessor key per processor GetSystemInfo reports. */
static inline unsigned int hwreg_cpu_count( unsigned long count )
{
    if (count < 1) return 1;
    if (count > HWREG_MAX_CPUS) return HWREG_MAX_CPUS;
    return (unsigned int)count;
}

/* The guest's TSC rate in Hz: FEX's SmallTSCScale applied to CNTFRQ_EL0. */
static inline uint64_t hwreg_fex_tsc_hz( uint64_t cntfrq )
{
    uint64_t hz = cntfrq;

    if (hz && hz < HWREG_TSC_SCALE_MAXIMUM)
        while (hz < HWREG_TSC_SCALE_MAXIMUM) hz <<= 1;
    return hz;
}

/* SSE4.2 follows SupportsCRC, which the iOS branch of FetchHostFeatures always
 * sets for the ARM64EC module. */
static inline void hwreg_fex_cpu( struct hwreg_cpu *cpu, uint64_t cntfrq )
{
    const uint32_t eax = HWREG_FEX_STEPPING | HWREG_FEX_MODEL << 4 | HWREG_FEX_FAMILY << 8 |
                         HWREG_FEX_EXT_MODEL << 16 | HWREG_FEX_EXT_FAMILY << 20;
    size_t n;

    memset( cpu, 0, sizeof(*cpu) );
    snprintf( cpu->vendor, sizeof(cpu->vendor), "%s", HWREG_FEX_VENDOR );
    snprintf( cpu->brand, sizeof(cpu->brand), "%s", HWREG_FEX_BRAND );
    /* trailing blanks off, as ntdll does for the SMBIOS processor name */
    for (n = strlen( cpu->brand ); n && cpu->brand[n - 1] == ' '; n--) cpu->brand[n - 1] = 0;

    /* FEX's CPUFeatures constructor (UpdateProcessorInformation hands these to the guest) */
    cpu->level = ((eax >> 8) & 0xf) + ((eax >> 20) & 0xff);
    cpu->revision = ((eax & 0xf0000) >> 4) | ((eax & 0xf0) << 4) | (eax & 0xf);

    /* wineboot, PROCESSOR_ARCHITECTURE_AMD64 */
    snprintf( cpu->identifier, sizeof(cpu->identifier), "%s Family %u Model %u Stepping %u",
              strcmp( cpu->vendor, "AuthenticAMD" ) ? "Intel64" : "AMD64",
              cpu->level, (cpu->revision >> 8) & 0xff, cpu->revision & 0xff );

    cpu->feature_set = HWREG_FEX_FEATURES | HWREG_CPU_FEATURE_SSE42;
    cpu->mhz = (uint32_t)(hwreg_fex_tsc_hz( cntfrq ) / 1000000);
}

/* wineboot's find_smbios_entry over a GetSystemFirmwareTable('RSMB') buffer:
 * an 8-byte prologue (DWORD table length at offset 4), then the entries. */
static inline const unsigned char *hwreg_smbios_entry( unsigned int type, unsigned int index,
                                                      const unsigned char *buf, size_t len )
{
    const unsigned char *ptr, *start, *hdr;
    uint32_t length;

    if (!buf || len < 8) return NULL;
    memcpy( &length, buf + 4, sizeof(length) );
    if (length > len - 8 || length < 4) return NULL;

    start = buf + 8;
    hdr = start;
    for (;;)
    {
        if ((size_t)(hdr - start) >= length - 4) return NULL;
        if (!hdr[1]) return NULL;   /* invalid entry */

        if (hdr[0] == type)
        {
            if ((size_t)(hdr - start) + hdr[1] > length) return NULL;
            if (!index--) return hdr;
        }
        /* skip other entries and their strings */
        for (ptr = hdr + hdr[1]; (size_t)(ptr - buf) < len && *ptr; ptr++)
        {
            for (; (size_t)(ptr - buf) < len; ptr++) if (!*ptr) break;
        }
        if (ptr == hdr + hdr[1]) ptr++;
        if ((size_t)(ptr - buf) >= len) return NULL;   /* truncated table: no next entry */
        hdr = ptr + 1;
    }
}

/* wineboot's get_smbios_string: string number `id` of the set starting at
 * `offset`; 0 when there is none. Bounded by `len` and by `size`. */
static inline int hwreg_smbios_string( unsigned int id, const unsigned char *buf, size_t offset,
                                       size_t len, char *out, size_t size )
{
    const unsigned char *ptr;
    unsigned int i = 0;

    out[0] = 0;
    if (!id || offset >= len) return 0;
    for (ptr = buf + offset; (size_t)(ptr - buf) < len && *ptr; ptr++)
    {
        if (++i == id)
        {
            size_t n = 0;
            while ((size_t)(ptr - buf) + n < len && ptr[n] && n + 1 < size)
            {
                out[n] = (char)ptr[n];
                n++;
            }
            out[n] = 0;
            return 1;
        }
        for (; (size_t)(ptr - buf) < len; ptr++) if (!*ptr) break;
    }
    return 0;
}

/* One string field of entry `hdr` (`field` = offset of its string number in
 * the formatted area, 0 = wineboot reads none); the host's string when there is
 * a non-empty one, else Wine's generic value (counted in `defaults` unless it
 * is empty too, as SKU and family are in Wine's own tables). */
static inline void hwreg_field( char *out, const unsigned char *buf, size_t len, const unsigned char *hdr,
                                unsigned int field, const char *fallback, unsigned int *defaults )
{
    unsigned int id = (hdr && field && field < hdr[1]) ? hdr[field] : 0;

    if (!hdr || !hwreg_smbios_string( id, buf, (size_t)(hdr - buf) + hdr[1], len, out, HWREG_STR ) || !out[0])
    {
        snprintf( out, HWREG_STR, "%s", fallback );
        if (fallback[0]) (*defaults)++;
    }
}

/* The BIOS key's values from the SMBIOS table (NULL/0 = none), with the field
 * rules of wineboot's create_bios_{baseboard,bios,system}_values. */
static inline void hwreg_bios_values( struct hwreg_bios *b, const unsigned char *buf, size_t len,
                                      const char *wine_version )
{
    const unsigned char *bios = hwreg_smbios_entry( HWREG_SMBIOS_BIOS, 0, buf, len );
    const unsigned char *sys = hwreg_smbios_entry( HWREG_SMBIOS_SYSTEM, 0, buf, len );
    const unsigned char *board = hwreg_smbios_entry( HWREG_SMBIOS_BASEBOARD, 0, buf, len );
    int sys_ext = sys && sys[1] >= 0x1b;   /* SKU and family exist from SMBIOS 2.4 */

    memset( b, 0, sizeof(*b) );
    b->found = (bios ? HWREG_FOUND_BIOS : 0) | (sys ? HWREG_FOUND_SYSTEM : 0) | (board ? HWREG_FOUND_BOARD : 0);

    /* type 2: vendor 4, product 5, version 6 */
    hwreg_field( b->board_vendor, buf, len, board, 4, HWREG_WINE_VENDOR, &b->defaults );
    hwreg_field( b->board_product, buf, len, board, 5, HWREG_WINE_PRODUCT, &b->defaults );
    hwreg_field( b->board_version, buf, len, board, 6, wine_version, &b->defaults );

    /* type 0: vendor 4, version 5, date 8; the four release bytes at 0x14 from length 0x18 */
    hwreg_field( b->bios_vendor, buf, len, bios, 4, HWREG_WINE_VENDOR, &b->defaults );
    hwreg_field( b->bios_version, buf, len, bios, 5, wine_version, &b->defaults );
    hwreg_field( b->bios_date, buf, len, bios, 8, HWREG_WINE_DATE, &b->defaults );
    if (bios && bios[1] >= 0x18)
    {
        b->bios_major = bios[0x14];
        b->bios_minor = bios[0x15];
        b->ec_major = bios[0x16];
        b->ec_minor = bios[0x17];
    }
    else b->bios_major = b->bios_minor = b->ec_major = b->ec_minor = 0xff;

    /* type 1: vendor 4, product 5, version 6; SKU 0x19 and family 0x1a from length 0x1b */
    hwreg_field( b->sys_vendor, buf, len, sys, 4, HWREG_WINE_VENDOR, &b->defaults );
    hwreg_field( b->sys_product, buf, len, sys, 5, HWREG_WINE_PRODUCT, &b->defaults );
    hwreg_field( b->sys_version, buf, len, sys, 6, wine_version, &b->defaults );
    hwreg_field( b->sys_sku, buf, len, sys, sys_ext ? 0x19 : 0, "", &b->defaults );
    hwreg_field( b->sys_family, buf, len, sys, sys_ext ? 0x1a : 0, "", &b->defaults );
}

#endif /* MADEIRA_HW_REGISTRY_IOS_H */
