/* iOS-Madeira: ONE D3DKMT adapter for the GPU that DXGI, NVAPI and
 * madeira_d3d12 report -- opt-in, MADEIRA_KMT_ADAPTER=1 (env.MADEIRA_KMT_ADAPTER
 * in madeira.cfg).
 *
 * Shared by two iOS overrides of win32u:
 *   d3dkmt_ios.c    (wraps upstream d3dkmt.c) -- the switch, the adapter LUID,
 *                   the dedicated size, the QueryAdapterInfo /
 *                   QueryStatistics / QueryVideoMemoryInfo answers and the
 *                   [vkmt] trace of the D3DKMT entry points implemented there
 *                   (MADEIRA_KMT_TRACE=0 silences it);
 *   sysparams_ios.c -- EnumAdapters2 / OpenAdapterFromDeviceName /
 *                   OpenAdapterFromGdiDisplayName list and open that adapter,
 *                   the registry GPU gets its LUID, and madeira_kmt_identity()
 *                   says what the registry GPU is.
 *
 * Without the switch both files answer exactly what they answered before. */
#ifndef MADEIRA_KMT_H
#define MADEIRA_KMT_H

struct madeira_kmt_identity
{
    unsigned short     vendor, device;     /* PCI ids of the registry GPU (10de:2544 or 106b:0001) */
    char               name[128];          /* "NVIDIA GeForce RTX 3060" */
    char               driver_version[32]; /* registry DriverVersion, "32.0.15.8157" */
    char               path[128];          /* PCI\VEN_10DE&DEV_2544&SUBSYS_00000000&REV_00\00000000 */
    unsigned long long dedicated;          /* bytes: vram-mb, else 4096 MB (the registry's memory size) */
};

/* d3dkmt_ios.c */
int madeira_kmt_adapter_enabled(void);                  /* env MADEIRA_KMT_ADAPTER = 1 / on / true / yes */
int madeira_kmt_adapter_luid( LUID *luid );             /* bswap64(MTLDevice.registryID), as DXGI's GetAdapterLuid */
unsigned long long madeira_kmt_dedicated_bytes(void);   /* the adapter's dedicated memory / LOCAL budget */
unsigned long long madeira_kmt_driver_version_qword( const char *version );  /* "a.b.c.d" -> a<<48|b<<32|c<<16|d */
int madeira_kmt_trace_enabled(void);                    /* the [vkmt] trace; env MADEIRA_KMT_TRACE = 0 turns it off */

/* sysparams_ios.c */
void madeira_kmt_identity( struct madeira_kmt_identity *id );

#endif /* MADEIRA_KMT_H */
