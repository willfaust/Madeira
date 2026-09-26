/*
 * nsiproxy.sys
 *
 * Copyright 2021 Huw Davies
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */
/* iOS uses Wine's BSD interface/address providers without the driver service.
 * Keep the dispatcher ABI and size validation shared across native and WoW callers.
 * MADEIRA_NSI_NETWORK_TABLES=0 restores the original unsupported-table behavior. */
#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "ifdef.h"
#define __WINE_INIT_NPI_MODULEID
#define USE_WS_PREFIX
#include "netiodef.h"
#include "wine/nsi.h"
#include "wine/debug.h"
#include "../../wine/dlls/nsiproxy.sys/unix_private.h"
WINE_DEFAULT_DEBUG_CHANNEL(nsi);

static const struct module *modules[] =
{
    &ndis_module,
    &ipv4_module,
    &ipv6_module,
};

static const struct module_table *get_module_table( const NPI_MODULEID *id, UINT table )
{
    const char *enabled = getenv( "MADEIRA_NSI_NETWORK_TABLES" );
    const struct module_table *entry;
    int i;

    if (enabled && !strcmp( enabled, "0" )) return NULL;
    if (!id) return NULL;
    for (i = 0; i < ARRAY_SIZE(modules); i++)
        if (NmrIsEqualNpiModuleId( modules[i]->module, id ))
            for (entry = modules[i]->tables; entry->table != ~0u; entry++)
                if (entry->table == table) return entry;

    return NULL;
}

/* ml1510: A SHORT-LIVED CACHE FOR INTERFACE, ADDRESS AND ROUTE TABLES.
 *
 * Device log 195: a launcher's network-watch thread read these tables about
 * 1,700 times a second. Each read rebuilds the whole table from the host
 * (getifaddrs, routing sysctls), for data that changes a few times a minute
 * at most. An identical request (module, table, both arguments, the four row
 * sizes) inside MADEIRA_NSI_CACHE_MS (default 500; 0 disables) is answered
 * from the last successful reading with the provider's exact semantics: all
 * rows and their count, or STATUS_BUFFER_OVERFLOW with the count untouched
 * when the caller's buffer is too small. TCP connection tables never come
 * here (nsi_unixlib_ios.c serves them live; loopback peer checks need them
 * fresh). [nsi-rate] ml1510 prints a 10 s summary while tables are read. */
#include <pthread.h>
#include <time.h>

#define IOS_NSI_CACHE_SLOTS 8
#define IOS_NSI_CACHE_MAX_BYTES (1u << 20)

struct ios_nsi_cache_slot
{
    NPI_MODULEID module;
    UINT table, first_arg, second_arg, sizes[4];
    UINT count;
    BOOL want_data;
    unsigned char *rows[4];
    unsigned long long when_ms;
    BOOL used;
};

static pthread_mutex_t ios_nsi_cache_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ios_nsi_cache_slot ios_nsi_cache[IOS_NSI_CACHE_SLOTS];
static unsigned long long ios_nsi_rate_t0, ios_nsi_rate_calls, ios_nsi_rate_hits, ios_nsi_rate_miss_us;
static unsigned long long ios_nsi_get_calls;   /* per-row lookups, read and reset by the summary */
static struct { unsigned int module, table; unsigned long long n; } ios_nsi_rate_keys[8];
/* ml1520: who reads — per thread, with its program's base name */
static struct { unsigned int tid; unsigned long long n; char image[40]; } ios_nsi_rate_readers[4];

static unsigned long long ios_nsi_now_us( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (unsigned long long)ts.tv_sec * 1000000ull + ts.tv_nsec / 1000;
}

static unsigned int ios_nsi_cache_ms( void )
{
    static int value = -1;
    if (value < 0)
    {
        const char *e = getenv( "MADEIRA_NSI_CACHE_MS" );
        value = e && *e ? atoi( e ) : 500;
        if (value < 0) value = 0;
        if (value > 5000) value = 5000;
    }
    return value;
}

/* ios_nsi_cache_lock held. */
static void ios_nsi_rate_note( const struct nsi_enumerate_all_ex *params, BOOL hit, unsigned long long miss_us,
                               unsigned long long now_us )
{
    unsigned int i, module = params->module->Guid.Data1;

    ios_nsi_rate_calls++;
    if (hit) ios_nsi_rate_hits++;
    ios_nsi_rate_miss_us += miss_us;
    for (i = 0; i < ARRAY_SIZE(ios_nsi_rate_keys); i++)
    {
        if (ios_nsi_rate_keys[i].n && (ios_nsi_rate_keys[i].module != module || ios_nsi_rate_keys[i].table != params->table))
            continue;
        ios_nsi_rate_keys[i].module = module;
        ios_nsi_rate_keys[i].table = params->table;
        ios_nsi_rate_keys[i].n++;
        break;
    }
    {
        TEB *teb = NtCurrentTeb();
        unsigned int tid = (unsigned int)HandleToULong( teb->ClientId.UniqueThread );
        for (i = 0; i < ARRAY_SIZE(ios_nsi_rate_readers); i++)
        {
            if (ios_nsi_rate_readers[i].n && ios_nsi_rate_readers[i].tid != tid) continue;
            if (!ios_nsi_rate_readers[i].n)
            {
                const RTL_USER_PROCESS_PARAMETERS *pp = teb->Peb ? teb->Peb->ProcessParameters : NULL;
                const WCHAR *path = pp ? pp->ImagePathName.Buffer : NULL;
                unsigned int len = pp && path ? pp->ImagePathName.Length / sizeof(WCHAR) : 0, k, start = 0;
                for (k = 0; k < len; k++) if (path[k] == '\\' || path[k] == '/') start = k + 1;
                for (k = 0; start + k < len && k < sizeof(ios_nsi_rate_readers[i].image) - 1; k++)
                    ios_nsi_rate_readers[i].image[k] = path[start + k] < 128 ? (char)path[start + k] : '?';
                ios_nsi_rate_readers[i].image[k] = 0;
                ios_nsi_rate_readers[i].tid = tid;
            }
            ios_nsi_rate_readers[i].n++;
            break;
        }
    }
    if (!ios_nsi_rate_t0) ios_nsi_rate_t0 = now_us;
    if (now_us - ios_nsi_rate_t0 < 10000000ull) return;
    {
        char line[400];
        int n = snprintf( line, sizeof(line), "[nsi-rate] ml1510 %llus reads=%llu hits=%llu miss-time=%llums cache=%ums gets=%llu |",
                          (now_us - ios_nsi_rate_t0) / 1000000ull, ios_nsi_rate_calls, ios_nsi_rate_hits,
                          ios_nsi_rate_miss_us / 1000, ios_nsi_cache_ms(),
                          __atomic_exchange_n( &ios_nsi_get_calls, 0, __ATOMIC_RELAXED ) );
        for (i = 0; i < ARRAY_SIZE(ios_nsi_rate_keys) && ios_nsi_rate_keys[i].n && n < (int)sizeof(line) - 40; i++)
            n += snprintf( line + n, sizeof(line) - n, " %08x/%u=%llu", ios_nsi_rate_keys[i].module,
                           ios_nsi_rate_keys[i].table, ios_nsi_rate_keys[i].n );
        for (i = 0; i < ARRAY_SIZE(ios_nsi_rate_readers) && ios_nsi_rate_readers[i].n && n < (int)sizeof(line) - 60; i++)
            n += snprintf( line + n, sizeof(line) - n, "%s %s/%04x=%llu", i ? "" : " | by (ml1520)",
                           ios_nsi_rate_readers[i].image, ios_nsi_rate_readers[i].tid, ios_nsi_rate_readers[i].n );
        dprintf( 2, "%s\n", line );
    }
    ios_nsi_rate_t0 = now_us;
    ios_nsi_rate_calls = ios_nsi_rate_hits = ios_nsi_rate_miss_us = 0;
    memset( ios_nsi_rate_keys, 0, sizeof(ios_nsi_rate_keys) );
    memset( ios_nsi_rate_readers, 0, sizeof(ios_nsi_rate_readers) );
}

static BOOL ios_nsi_cache_match( const struct ios_nsi_cache_slot *slot, const struct nsi_enumerate_all_ex *params,
                                 const UINT sizes[4], BOOL want_data )
{
    return slot->used && slot->want_data == want_data && slot->table == params->table
        && slot->first_arg == params->first_arg && slot->second_arg == params->second_arg
        && !memcmp( slot->sizes, sizes, sizeof(slot->sizes) )
        && NmrIsEqualNpiModuleId( &slot->module, params->module );
}

static NTSTATUS ios_nsi_cached_enumerate( struct nsi_enumerate_all_ex *params, const struct module_table *entry,
                                          void *data[4], const UINT sizes[4] )
{
    unsigned int ttl = ios_nsi_cache_ms(), i;
    BOOL want_data = data[0] || data[1] || data[2] || data[3];
    unsigned long long start = ios_nsi_now_us(), took;
    struct ios_nsi_cache_slot *slot, *victim = NULL;
    UINT capacity = params->count;
    NTSTATUS status;

    pthread_mutex_lock( &ios_nsi_cache_lock );
    for (i = 0; ttl && i < IOS_NSI_CACHE_SLOTS; i++)
    {
        slot = &ios_nsi_cache[i];
        if (!ios_nsi_cache_match( slot, params, sizes, want_data )) continue;
        if (start / 1000 - slot->when_ms > ttl) break;
        if (want_data && slot->count > capacity)
            status = STATUS_BUFFER_OVERFLOW;
        else
        {
            int j;
            for (j = 0; j < 4; j++)
                if (data[j] && slot->count) memcpy( data[j], slot->rows[j], (size_t)slot->count * sizes[j] );
            params->count = slot->count;
            status = STATUS_SUCCESS;
        }
        ios_nsi_rate_note( params, TRUE, 0, start );
        pthread_mutex_unlock( &ios_nsi_cache_lock );
        return status;
    }
    pthread_mutex_unlock( &ios_nsi_cache_lock );

    status = entry->enumerate_all( data[0], sizes[0], data[1], sizes[1], data[2], sizes[2], data[3], sizes[3], &params->count );
    took = ios_nsi_now_us() - start;

    pthread_mutex_lock( &ios_nsi_cache_lock );
    if (ttl && status == STATUS_SUCCESS)
    {
        size_t bytes = 0;
        for (i = 0; i < 4; i++) bytes += (size_t)params->count * sizes[i];
        /* The same request's slot, else an empty one, else the oldest. */
        for (i = 0; i < IOS_NSI_CACHE_SLOTS && !victim; i++)
            if (ios_nsi_cache_match( &ios_nsi_cache[i], params, sizes, want_data )) victim = &ios_nsi_cache[i];
        for (i = 0; i < IOS_NSI_CACHE_SLOTS && !victim; i++)
            if (!ios_nsi_cache[i].used) victim = &ios_nsi_cache[i];
        if (!victim)
        {
            victim = &ios_nsi_cache[0];
            for (i = 1; i < IOS_NSI_CACHE_SLOTS; i++)
                if (ios_nsi_cache[i].when_ms < victim->when_ms) victim = &ios_nsi_cache[i];
        }
        if (bytes <= IOS_NSI_CACHE_MAX_BYTES)
        {
            BOOL ok = TRUE;
            for (i = 0; i < 4; i++)
            {
                free( victim->rows[i] );
                victim->rows[i] = NULL;
                if (data[i] && params->count)
                {
                    if (!(victim->rows[i] = malloc( (size_t)params->count * sizes[i] ))) ok = FALSE;
                    else memcpy( victim->rows[i], data[i], (size_t)params->count * sizes[i] );
                }
            }
            victim->used = ok;
            victim->module = *params->module;
            victim->table = params->table;
            victim->first_arg = params->first_arg;
            victim->second_arg = params->second_arg;
            memcpy( victim->sizes, sizes, sizeof(victim->sizes) );
            victim->count = params->count;
            victim->want_data = want_data;
            victim->when_ms = ios_nsi_now_us() / 1000;
        }
    }
    ios_nsi_rate_note( params, FALSE, took, start );
    pthread_mutex_unlock( &ios_nsi_cache_lock );
    return status;
}

NTSTATUS nsi_enumerate_all_ex( struct nsi_enumerate_all_ex *params )
{
    const struct module_table *entry = get_module_table( params->module, params->table );
    UINT sizes[4] = { params->key_size, params->rw_size, params->dynamic_size, params->static_size };
    void *data[4] = { params->key_data, params->rw_data, params->dynamic_data, params->static_data };
    int i;

    if (!entry || !entry->enumerate_all)
    {
        WARN( "table not found\n" );
        return STATUS_NOT_SUPPORTED;
    }

    for (i = 0; i < ARRAY_SIZE(sizes); i++)
    {
        if (!sizes[i]) data[i] = NULL;
        else if (!data[i] || sizes[i] != entry->sizes[i]) return STATUS_INVALID_PARAMETER;
    }

    NTSTATUS status = ios_nsi_cached_enumerate( params, entry, data, sizes );
    static unsigned int reports;
    if (__atomic_fetch_add( &reports, 1, __ATOMIC_RELAXED ) < 16)
        dprintf( 2, "[nsi-network] ml1290 module=%08x table=%u status=%08x count=%u\n",
                 params->module->Guid.Data1, (UINT)params->table, (UINT)status, (UINT)params->count );
    return status;
}

NTSTATUS nsi_get_all_parameters_ex( struct nsi_get_all_parameters_ex *params )
{
    __atomic_fetch_add( &ios_nsi_get_calls, 1, __ATOMIC_RELAXED );   /* ml1510 [nsi-rate] */
    const struct module_table *entry = get_module_table( params->module, params->table );
    void *rw = params->rw_data;
    void *dyn = params->dynamic_data;
    void *stat = params->static_data;

    if (!entry || !entry->get_all_parameters)
    {
        WARN( "table not found\n" );
        return STATUS_NOT_SUPPORTED;
    }

    if ((params->key_size && !params->key) || params->key_size != entry->sizes[0]) return STATUS_INVALID_PARAMETER;
    if (!params->rw_size) rw = NULL;
    else if (!rw || params->rw_size != entry->sizes[1]) return STATUS_INVALID_PARAMETER;
    if (!params->dynamic_size) dyn = NULL;
    else if (!dyn || params->dynamic_size != entry->sizes[2]) return STATUS_INVALID_PARAMETER;
    if (!params->static_size) stat = NULL;
    else if (!stat || params->static_size != entry->sizes[3]) return STATUS_INVALID_PARAMETER;

    return entry->get_all_parameters( params->key, params->key_size, rw, params->rw_size,
                                      dyn, params->dynamic_size, stat, params->static_size );
}

NTSTATUS nsi_get_parameter_ex( struct nsi_get_parameter_ex *params )
{
    __atomic_fetch_add( &ios_nsi_get_calls, 1, __ATOMIC_RELAXED );   /* ml1510 [nsi-rate] */
    const struct module_table *entry = get_module_table( params->module, params->table );

    if (!entry || !entry->get_parameter)
    {
        WARN( "table not found\n" );
        return STATUS_NOT_SUPPORTED;
    }

    if (params->param_type > 2) return STATUS_INVALID_PARAMETER;
    if ((params->key_size && !params->key) || params->key_size != entry->sizes[0]) return STATUS_INVALID_PARAMETER;
    if ((params->data_size && !params->data) ||
        params->data_offset > entry->sizes[params->param_type + 1] ||
        params->data_size > entry->sizes[params->param_type + 1] - params->data_offset)
        return STATUS_INVALID_PARAMETER;
    return entry->get_parameter( params->key, params->key_size, params->param_type,
                                 params->data, params->data_size, params->data_offset );
}

