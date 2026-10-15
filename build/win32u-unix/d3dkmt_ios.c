/*
 * D3DKMT entry points, iOS override
 *
 * Copyright 2026 bahacan16
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

/* Wraps wine/dlls/win32u/d3dkmt.c (compiled unchanged, four adapter entry
 * points renamed upstream_*) for one opt-in feature.
 *
 * The iOS virtual-monitor regime has no GPU in win32u's list, so D3DKMT knows
 * no adapter: EnumAdapters2 lists none, QueryAdapterInfo answers two types,
 * QueryStatistics fills nothing. Engines and SDKs that check the driver
 * through D3DKMT (Streamline's hardware-scheduling check, GTA V Enhanced's
 * device check) find no driver behind the D3D12 device.
 *
 * With MADEIRA_KMT_ADAPTER=1 (default off; nothing below changes an answer
 * without it) the D3D12/DXGI GPU becomes a D3DKMT adapter. Its LUID is the one
 * DXGI's GetAdapterLuid, NVAPI and madeira_d3d12 report -- bswap64 of the Metal
 * device's registryID -- computed here from MTLCreateSystemDefaultDevice
 * (resolved with dlsym, so this file needs no Objective-C and no link change).
 * EnumAdapters2 lists it (sysparams_ios.c), OpenAdapterFromHdc opens it, and
 * QueryAdapterInfo answers for it like a WDDM 3.1 desktop driver:
 * DRIVERVERSION, UMD/KMD_DRIVER_VERSION (the registry DriverVersion, Windows'
 * a.b.c.d -> a<<48|b<<32|c<<16|d), ADAPTERTYPE, PHYSICALADAPTERCOUNT /
 * DEVICEIDS, ADAPTERADDRESS, the WDDM 1.2 .. 3.1 caps (hardware scheduling on),
 * DRIVER_DESCRIPTION, ADAPTERREGISTRYINFO, NODEMETADATA, GETSEGMENTSIZE /
 * GETSEGMENTGROUPSIZE (dedicated = vram-mb, else 4096 MB), ADAPTERPERFDATA and
 * ADAPTERPERFDATA_CAPS. Every other type keeps upstream's answer.
 * QueryStatistics describes the adapter, its segments and nodes, and
 * QueryVideoMemoryInfo's LOCAL budget (upstream: 0 without Vulkan) becomes the
 * same dedicated size. */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "../madeira_cfg.h"   /* before Wine's headers, which poison strncpy */

#include <pthread.h>

/* D3DKMT's Vulkan instance (get_d3dkmt_vulkan_instance, the file's only
 * pthread_once) is NULL on a thread that is inside Vulkan's own set-up: that
 * set-up loads the display driver, which lists Vulkan's GPUs through this
 * instance, which would enter Vulkan's set-up again inside its pthread_once
 * (vulkan_ios.c). Vulkan is off unless the session asks for it. */
extern int madeira_vulkan_init_on_this_thread( void );
static int madeira_d3dkmt_pthread_once( pthread_once_t *once, void (*init)(void) )
{
    if (madeira_vulkan_init_on_this_thread()) return 0;
    return pthread_once( once, init );
}

#define NtGdiDdDDIOpenAdapterFromHdc            upstream_NtGdiDdDDIOpenAdapterFromHdc
#define NtGdiDdDDIQueryAdapterInfo              upstream_NtGdiDdDDIQueryAdapterInfo
#define NtGdiDdDDIQueryStatistics               upstream_NtGdiDdDDIQueryStatistics
#define NtGdiDdDDIQueryVideoMemoryInfo          upstream_NtGdiDdDDIQueryVideoMemoryInfo
#define pthread_once( once, init )              madeira_d3dkmt_pthread_once( once, init )
#include "../../wine/dlls/win32u/d3dkmt.c"
#undef NtGdiDdDDIOpenAdapterFromHdc
#undef NtGdiDdDDIQueryAdapterInfo
#undef NtGdiDdDDIQueryStatistics
#undef NtGdiDdDDIQueryVideoMemoryInfo
#undef pthread_once

#include "madeira_kmt.h"

/* The headers declared the renamed names; these are the exported ones. */
NTSTATUS WINAPI NtGdiDdDDIOpenAdapterFromHdc( D3DKMT_OPENADAPTERFROMHDC *desc );
NTSTATUS WINAPI NtGdiDdDDIQueryAdapterInfo( D3DKMT_QUERYADAPTERINFO *desc );
NTSTATUS WINAPI NtGdiDdDDIQueryStatistics( D3DKMT_QUERYSTATISTICS *stats );
NTSTATUS WINAPI NtGdiDdDDIQueryVideoMemoryInfo( D3DKMT_QUERYVIDEOMEMORYINFO *desc );

/* kmt-test:begin -- tests/host/check-kmt-adapter.py compiles this region on the host. */

/* Windows SDK (d3dkmthk.h / d3dukmdt.h) layouts Wine's header does not have;
 * madeira_ names so a newer Wine header cannot clash. */
struct madeira_kmt_device_ids { UINT VendorID, DeviceID, SubVendorID, SubSystemID, RevisionID, BusType; };
struct madeira_kmt_query_device_ids { UINT PhysicalAdapterIndex; struct madeira_kmt_device_ids DeviceIds; };
struct madeira_kmt_adapteraddress { UINT BusNumber, DeviceNumber, FunctionNumber; };
struct madeira_kmt_adapterregistryinfo { WCHAR AdapterString[260], BiosString[260], DacType[260], ChipType[260]; };
struct madeira_kmt_driver_description { WCHAR DriverDescription[4096]; };
struct madeira_kmt_segmentsizeinfo
{
    ULONGLONG DedicatedVideoMemorySize, DedicatedSystemMemorySize, SharedSystemMemorySize;
};
struct madeira_kmt_segmentgroupsizeinfo
{
    UINT PhysicalAdapterIndex;
    struct madeira_kmt_segmentsizeinfo LegacyInfo;
    ULONGLONG LocalMemory, NonLocalMemory, NonBudgetMemory;
};
struct madeira_kmt_nodemetadata   /* D3DKMT_NODEMETADATA with DXGK_NODEMETADATA inline */
{
    UINT NodeOrdinalAndAdapterIndex;  /* in: node ordinal (low word), physical adapter (high word) */
    UINT EngineType;                  /* DXGK_ENGINE_TYPE */
    WCHAR FriendlyName[32];
    UINT Flags;
    unsigned char GpuMmuSupported, IoMmuSupported;
};
struct madeira_kmt_wddm_1_2_caps { UINT GraphicsPreemptionGranularity, ComputePreemptionGranularity, Value; };
/* D3DKMT_ADAPTER_PERFDATA (64 bytes) and D3DKMT_ADAPTER_PERFDATACAPS. The caps
 * are filled as far as the caller's buffer goes (the SDK's temperature fields
 * sit past 40 bytes, and GTA V Enhanced passes 40). */
struct madeira_kmt_adapter_perfdata
{
    UINT PhysicalAdapterIndex;
    ULONGLONG MemoryFrequency, MaxMemoryFrequency, MaxMemoryFrequencyOC, MemoryBandwidth, PCIEBandwidth;
    UINT FanRPM, Power, Temperature;
    unsigned char PowerStateOverride;
};
struct madeira_kmt_adapter_perfdatacaps
{
    UINT PhysicalAdapterIndex;
    ULONGLONG MaxMemoryBandwidth, MaxPCIEBandwidth, MaxReadBandwidth, MaxWriteBandwidth;
    UINT TemperatureMax, TemperatureWarning;
};
_Static_assert( sizeof(struct madeira_kmt_adapter_perfdata) == 64, "D3DKMT_ADAPTER_PERFDATA" );
_Static_assert( sizeof(struct madeira_kmt_query_device_ids) == 28, "D3DKMT_QUERY_DEVICE_IDS" );
_Static_assert( sizeof(struct madeira_kmt_adapteraddress) == 12, "D3DKMT_ADAPTERADDRESS" );
_Static_assert( sizeof(struct madeira_kmt_adapterregistryinfo) == 2080, "D3DKMT_ADAPTERREGISTRYINFO" );
_Static_assert( sizeof(struct madeira_kmt_driver_description) == 8192, "D3DKMT_DRIVER_DESCRIPTION" );
_Static_assert( sizeof(struct madeira_kmt_segmentsizeinfo) == 24, "D3DKMT_SEGMENTSIZEINFO" );
_Static_assert( sizeof(struct madeira_kmt_segmentgroupsizeinfo) == 56, "D3DKMT_SEGMENTGROUPSIZEINFO" );
_Static_assert( sizeof(struct madeira_kmt_nodemetadata) == 80, "D3DKMT_NODEMETADATA" );
_Static_assert( sizeof(struct madeira_kmt_wddm_1_2_caps) == 12, "D3DKMT_WDDM_1_2_CAPS" );

/* Windows' driver version QWORD (DXGI CheckInterfaceSupport, KMT UMD version,
 * the DirectX registry key): "a.b.c.d" -> a<<48 | b<<32 | c<<16 | d. */
unsigned long long madeira_kmt_driver_version_qword( const char *v )
{
    unsigned long long q = 0;
    unsigned int i;

    for (i = 0; i < 4; i++)
    {
        unsigned long n = 0;
        while (v && *v >= '0' && *v <= '9')
        {
            n = n * 10 + (unsigned long)(*v++ - '0');
            if (n > 0xffff) n = 0xffff;
        }
        q = (q << 16) | n;
        if (v && *v == '.') v++;
        else v = NULL;
    }
    return q;
}

/* DXMT's GetAdapterLuid: bit_cast<LUID>(bswap64(registryID)). */
static void madeira_kmt_luid_from_registry_id( unsigned long long id, LUID *luid )
{
    unsigned long long v = __builtin_bswap64( id );
    luid->LowPart = (DWORD)v;
    luid->HighPart = (LONG)(v >> 32);
}

static void madeira_kmt_wstr( WCHAR *dst, unsigned int cap, const char *src )
{
    unsigned int i;
    for (i = 0; i + 1 < cap && src[i]; i++) dst[i] = (unsigned char)src[i];
    if (cap) dst[i] = 0;
}

/* The madeira adapter's answer to one QueryAdapterInfo type. Returns 1 when
 * answered here (*status set; the caller's buffer is written only on
 * success), 0 when upstream answers. A buffer smaller than the type's
 * structure gets STATUS_INVALID_PARAMETER, as on Windows. */
static int madeira_kmt_answer( UINT type, void *data, UINT size, const struct madeira_kmt_identity *id,
                               NTSTATUS *status )
{
#define KMT_NEED(n) do { if (size < (n)) { *status = STATUS_INVALID_PARAMETER; return 1; } } while (0)
    UINT value;

    *status = STATUS_SUCCESS;
    switch (type)
    {
    case KMTQAITYPE_DRIVERVERSION:
    case KMTQAITYPE_DRIVERVERSION_RENDER:
        value = KMT_DRIVERVERSION_WDDM_3_1;
        break;
    case KMTQAITYPE_UMD_DRIVER_VERSION:   /* D3DKMT_UMD_DRIVER_VERSION: LARGE_INTEGER */
    case KMTQAITYPE_KMD_DRIVER_VERSION:
    {
        unsigned long long version = madeira_kmt_driver_version_qword( id->driver_version );
        KMT_NEED( sizeof(version) );
        memcpy( data, &version, sizeof(version) );
        return 1;
    }
    case KMTQAITYPE_ADAPTERTYPE:          /* RenderSupported | DisplaySupported; not SoftwareDevice */
    case KMTQAITYPE_ADAPTERTYPE_RENDER:
        value = 0x3;
        break;
    case KMTQAITYPE_PHYSICALADAPTERCOUNT:
        value = 1;
        break;
    case KMTQAITYPE_WDDM_1_3_CAPS:        /* no Miracast, not a hybrid GPU, no P-state management */
    case KMTQAITYPE_WDDM_1_3_CAPS_RENDER:
        value = 0;
        break;
    case KMTQAITYPE_WDDM_2_0_CAPS:        /* Support64BitAtomics | GpuMmuSupported */
        value = 0x3;
        break;
    case KMTQAITYPE_WDDM_2_7_CAPS:        /* HwSchSupported | HwSchEnabled | HwSchEnabledByDefault */
        value = 0x7;
        break;
    case KMTQAITYPE_WDDM_2_9_CAPS:        /* HwSchSupportState = DXGK_FEATURE_SUPPORT_STABLE (2), HwSchEnabled */
        value = 0x2 | 0x4;
        break;
    case KMTQAITYPE_WDDM_3_0_CAPS:        /* no hardware flip queue */
    case KMTQAITYPE_WDDM_3_1_CAPS:        /* no native GPU fence */
        value = 0;
        break;
    case KMTQAITYPE_WDDM_1_2_CAPS:
    case KMTQAITYPE_WDDM_1_2_CAPS_RENDER:
    {
        /* DMA-buffer preemption, as DXGI's adapter desc says; SupportNonVGA,
         * SmoothRotation, PerEngineTDR, CCD, GammaRamp, HWCursor, HWVSync. */
        struct madeira_kmt_wddm_1_2_caps caps = { 100, 100, 0x1d7 };
        KMT_NEED( sizeof(caps) );
        memcpy( data, &caps, sizeof(caps) );
        return 1;
    }
    case KMTQAITYPE_PHYSICALADAPTERDEVICEIDS:
    {
        struct madeira_kmt_query_device_ids ids;
        KMT_NEED( sizeof(ids) );
        memcpy( &ids, data, sizeof(ids) );
        if (ids.PhysicalAdapterIndex)
        {
            *status = STATUS_INVALID_PARAMETER;
            return 1;
        }
        memset( &ids.DeviceIds, 0, sizeof(ids.DeviceIds) );
        ids.DeviceIds.VendorID = id->vendor;     /* subsystem and revision 0, as the registry path */
        ids.DeviceIds.DeviceID = id->device;
        ids.DeviceIds.BusType = 5;               /* PCIBus */
        memcpy( data, &ids, sizeof(ids) );
        return 1;
    }
    case KMTQAITYPE_ADAPTERADDRESS:       /* bus 0 (DEVPKEY_Device_BusNumber in the registry), device 0, function 0 */
    case KMTQAITYPE_ADAPTERADDRESS_RENDER:
    {
        struct madeira_kmt_adapteraddress address = { 0, 0, 0 };
        KMT_NEED( sizeof(address) );
        memcpy( data, &address, sizeof(address) );
        return 1;
    }
    case KMTQAITYPE_DRIVER_DESCRIPTION:
    case KMTQAITYPE_DRIVER_DESCRIPTION_RENDER:
        KMT_NEED( sizeof(struct madeira_kmt_driver_description) );
        memset( data, 0, sizeof(struct madeira_kmt_driver_description) );
        madeira_kmt_wstr( ((struct madeira_kmt_driver_description *)data)->DriverDescription, 4096, id->name );
        return 1;
    case KMTQAITYPE_ADAPTERREGISTRYINFO:  /* the strings write_gpu_to_registry stores */
    case KMTQAITYPE_ADAPTERREGISTRYINFO_RENDER:
    {
        struct madeira_kmt_adapterregistryinfo *info = data;
        KMT_NEED( sizeof(*info) );
        memset( info, 0, sizeof(*info) );
        madeira_kmt_wstr( info->AdapterString, 260, id->name );
        madeira_kmt_wstr( info->BiosString, 260, id->name );
        madeira_kmt_wstr( info->DacType, 260, "Integrated RAMDAC" );
        madeira_kmt_wstr( info->ChipType, 260, id->name );
        return 1;
    }
    case KMTQAITYPE_NODEMETADATA:
    {
        struct madeira_kmt_nodemetadata node;
        KMT_NEED( sizeof(node) );
        memcpy( &node, data, sizeof(node) );
        if ((node.NodeOrdinalAndAdapterIndex >> 16) || (node.NodeOrdinalAndAdapterIndex & 0xffff) > 1)
        {
            *status = STATUS_INVALID_PARAMETER;
            return 1;
        }
        memset( (char *)&node + sizeof(UINT), 0, sizeof(node) - sizeof(UINT) );
        if (!(node.NodeOrdinalAndAdapterIndex & 0xffff))
        {
            node.EngineType = 1;   /* DXGK_ENGINE_TYPE_3D */
            madeira_kmt_wstr( node.FriendlyName, 32, "3D" );
        }
        else
        {
            node.EngineType = 6;   /* DXGK_ENGINE_TYPE_COPY */
            madeira_kmt_wstr( node.FriendlyName, 32, "Copy" );
        }
        node.GpuMmuSupported = 1;
        memcpy( data, &node, sizeof(node) );
        return 1;
    }
    case KMTQAITYPE_GETSEGMENTSIZE:       /* what DXGI's adapter desc says: dedicated only */
    {
        struct madeira_kmt_segmentsizeinfo seg = { id->dedicated, 0, 0 };
        KMT_NEED( sizeof(seg) );
        memcpy( data, &seg, sizeof(seg) );
        return 1;
    }
    case KMTQAITYPE_ADAPTERPERFDATA_CAPS:   /* RTX 3060: 360 GB/s GDDR6, PCIe 4.0 x16 */
    {
        struct madeira_kmt_adapter_perfdatacaps caps = { 0, 360000000000ull, 31500000000ull,
                                                         360000000000ull, 360000000000ull, 930, 830 };
        KMT_NEED( 40 );
        caps.PhysicalAdapterIndex = ((const struct madeira_kmt_adapter_perfdatacaps *)data)->PhysicalAdapterIndex;
        if (caps.PhysicalAdapterIndex)
        {
            *status = STATUS_INVALID_PARAMETER;
            return 1;
        }
        memcpy( data, &caps, size < sizeof(caps) ? size : sizeof(caps) );
        return 1;
    }
    case KMTQAITYPE_ADAPTERPERFDATA:        /* idle desktop GPU: 1875 MHz memory, 45.0 C, 30 % power */
    {
        struct madeira_kmt_adapter_perfdata perf;
        KMT_NEED( sizeof(perf) );
        memset( &perf, 0, sizeof(perf) );
        perf.PhysicalAdapterIndex = ((const struct madeira_kmt_adapter_perfdata *)data)->PhysicalAdapterIndex;
        if (perf.PhysicalAdapterIndex)
        {
            *status = STATUS_INVALID_PARAMETER;
            return 1;
        }
        perf.MemoryFrequency = perf.MaxMemoryFrequency = 1875000000ull;
        perf.FanRPM = 1000;
        perf.Power = 300;
        perf.Temperature = 450;
        memcpy( data, &perf, sizeof(perf) );
        return 1;
    }
    case KMTQAITYPE_GETSEGMENTGROUPSIZE:
    {
        struct madeira_kmt_segmentgroupsizeinfo group;
        KMT_NEED( sizeof(group) );
        memcpy( &group, data, sizeof(group) );
        if (group.PhysicalAdapterIndex)
        {
            *status = STATUS_INVALID_PARAMETER;
            return 1;
        }
        group.LegacyInfo.DedicatedVideoMemorySize = id->dedicated;
        group.LegacyInfo.DedicatedSystemMemorySize = 0;
        group.LegacyInfo.SharedSystemMemorySize = 0;
        group.LocalMemory = id->dedicated;
        group.NonLocalMemory = 0;
        group.NonBudgetMemory = 0;
        memcpy( data, &group, sizeof(group) );
        return 1;
    }
    default:
        return 0;
    }

    KMT_NEED( sizeof(value) );
    memcpy( data, &value, sizeof(value) );
    return 1;
#undef KMT_NEED
}

/* kmt-test:end */

int madeira_kmt_adapter_enabled(void)
{
    static int enabled = -1;

    if (enabled < 0)
    {
        const char *v = getenv( "MADEIRA_KMT_ADAPTER" );
        enabled = v && (!strcmp( v, "1" ) || !strcasecmp( v, "on" ) || !strcasecmp( v, "true" ) ||
                        !strcasecmp( v, "yes" ));
    }
    return enabled;
}

static pthread_once_t madeira_kmt_luid_once = PTHREAD_ONCE_INIT;
static LUID madeira_kmt_luid_value;
static int madeira_kmt_luid_ok;

static void madeira_kmt_luid_init(void)
{
    void *(*create_device)(void) = (void *(*)(void))dlsym( RTLD_DEFAULT, "MTLCreateSystemDefaultDevice" );
    void *(*sel_register)(const char *) = (void *(*)(const char *))dlsym( RTLD_DEFAULT, "sel_registerName" );
    void *msg_send = dlsym( RTLD_DEFAULT, "objc_msgSend" );
    unsigned long long registry_id = 0;
    void *device = NULL;

    if (create_device && sel_register && msg_send && (device = create_device()))
    {
        registry_id = ((unsigned long long (*)(void *, void *))msg_send)( device, sel_register( "registryID" ) );
        ((void (*)(void *, void *))msg_send)( device, sel_register( "release" ) );   /* create returns +1 */
    }
    if (registry_id)
    {
        madeira_kmt_luid_from_registry_id( registry_id, &madeira_kmt_luid_value );
        madeira_kmt_luid_ok = 1;
        dprintf( 2, "[vkmt] MADEIRA_KMT_ADAPTER adapter LUID %08x:%08x (bswap64 of Metal registryID %#llx, "
                 "as DXGI / NVAPI / madeira_d3d12)\n", (unsigned)madeira_kmt_luid_value.HighPart,
                 (unsigned)madeira_kmt_luid_value.LowPart, registry_id );
    }
    else
        dprintf( 2, "[vkmt] MADEIRA_KMT_ADAPTER: no Metal device registryID, no adapter listed\n" );
}

int madeira_kmt_adapter_luid( LUID *luid )
{
    pthread_once( &madeira_kmt_luid_once, madeira_kmt_luid_init );
    if (madeira_kmt_luid_ok) *luid = madeira_kmt_luid_value;
    return madeira_kmt_luid_ok;
}

/* vram-mb when set (as winemetal's video budget), else the 4096 MB the
 * registry GPU is written with. */
unsigned long long madeira_kmt_dedicated_bytes(void)
{
    static unsigned long long cached;

    if (!cached)
    {
        long long mb = madeira_cfg_int( "vram-mb", 0 );
        cached = (unsigned long long)(mb >= 256 ? mb : 4096) << 20;
    }
    return cached;
}

static int kmt_is_ours( const LUID *luid )
{
    LUID ours;
    return madeira_kmt_adapter_enabled() && madeira_kmt_adapter_luid( &ours ) &&
           ours.LowPart == luid->LowPart && ours.HighPart == luid->HighPart;
}

/******************************************************************************
 *           NtGdiDdDDIOpenAdapterFromHdc    (win32u.@)
 */
NTSTATUS WINAPI NtGdiDdDDIOpenAdapterFromHdc( D3DKMT_OPENADAPTERFROMHDC *desc )
{
    D3DKMT_OPENADAPTERFROMLUID open;
    NTSTATUS status;
    LUID luid;

    if (!madeira_kmt_adapter_enabled() || !desc || !madeira_kmt_adapter_luid( &luid ))
        return upstream_NtGdiDdDDIOpenAdapterFromHdc( desc );

    /* One GPU drives every DC; same source id as OpenAdapterFromGdiDisplayName's virtual adapter. */
    memset( &open, 0, sizeof(open) );
    open.AdapterLuid = luid;
    if (!(status = NtGdiDdDDIOpenAdapterFromLuid( &open )))
    {
        desc->hAdapter = open.hAdapter;
        desc->AdapterLuid = luid;
        desc->VidPnSourceId = 1;
    }
    return status;
}

/******************************************************************************
 *           NtGdiDdDDIQueryAdapterInfo    (win32u.@)
 */
NTSTATUS WINAPI NtGdiDdDDIQueryAdapterInfo( D3DKMT_QUERYADAPTERINFO *desc )
{
    struct madeira_kmt_identity id;
    NTSTATUS status = STATUS_SUCCESS;

    if (madeira_kmt_adapter_enabled() && desc && desc->hAdapter && desc->pPrivateDriverData &&
        get_d3dkmt_object( desc->hAdapter, D3DKMT_ADAPTER ))
    {
        madeira_kmt_identity( &id );
        id.dedicated = madeira_kmt_dedicated_bytes();
        if (madeira_kmt_answer( desc->Type, desc->pPrivateDriverData, desc->PrivateDriverDataSize, &id, &status ))
            return status;
    }
    return upstream_NtGdiDdDDIQueryAdapterInfo( desc );
}

/******************************************************************************
 *           NtGdiDdDDIQueryStatistics    (win32u.@)
 */
NTSTATUS WINAPI NtGdiDdDDIQueryStatistics( D3DKMT_QUERYSTATISTICS *stats )
{
    NTSTATUS status = upstream_NtGdiDdDDIQueryStatistics( stats );

    /* The madeira adapter describes itself -- two segments (local video
     * memory, then the system-memory aperture), two nodes (3D, copy), one
     * source -- where upstream fills nothing. */
    if (!status && stats && kmt_is_ours( &stats->AdapterLuid ))
    {
        unsigned long long dedicated = madeira_kmt_dedicated_bytes();
        switch (stats->Type)
        {
        case D3DKMT_QUERYSTATISTICS_ADAPTER:
            memset( &stats->QueryResult.AdapterInformation, 0, sizeof(stats->QueryResult.AdapterInformation) );
            stats->QueryResult.AdapterInformation.NbSegments = 2;
            stats->QueryResult.AdapterInformation.NodeCount = 2;
            stats->QueryResult.AdapterInformation.VidPnSourceCount = 1;
            break;
        case D3DKMT_QUERYSTATISTICS_SEGMENT:
        {
            D3DKMT_QUERYSTATISTICS_SEGMENT_INFORMATION *seg = &stats->QueryResult.SegmentInformation;
            ULONG segment = stats->QuerySegment.SegmentId;
            if (segment > 1) return STATUS_INVALID_PARAMETER;
            memset( seg, 0, sizeof(*seg) );
            seg->CommitLimit = segment ? dedicated / 2 : dedicated;
            seg->Aperture = segment;
            break;
        }
        case D3DKMT_QUERYSTATISTICS_NODE:   /* idle */
            memset( &stats->QueryResult.NodeInformation, 0, sizeof(stats->QueryResult.NodeInformation) );
            break;
        default:
            break;
        }
    }
    return status;
}

/******************************************************************************
 *           NtGdiDdDDIQueryVideoMemoryInfo    (win32u.@)
 */
NTSTATUS WINAPI NtGdiDdDDIQueryVideoMemoryInfo( D3DKMT_QUERYVIDEOMEMORYINFO *desc )
{
    NTSTATUS status = upstream_NtGdiDdDDIQueryVideoMemoryInfo( desc );

    /* Upstream reads the budget from Vulkan and leaves zeros without it. */
    if (!status && madeira_kmt_adapter_enabled() && desc->MemorySegmentGroup == D3DKMT_MEMORY_SEGMENT_GROUP_LOCAL &&
        !desc->Budget)
    {
        desc->Budget = madeira_kmt_dedicated_bytes();
        desc->AvailableForReservation = desc->Budget / 2;
    }
    return status;
}
