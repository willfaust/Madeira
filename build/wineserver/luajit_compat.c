/*
 * Madeira: substitute a GC64 LuaJIT for x64 LuaJIT builds that cannot run on iOS
 *
 * Copyright 2026 Connor Gow
 * Written with AI assistance (Claude).
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

/*
 * A 64-bit LuaJIT built without GC64 (every 2.0.x, and 2.1 with GC64 off)
 * keeps 32-bit GC references, so it allocates its heap below 2 GB through
 * NtAllocateVirtualMemory with zero bits (LJ_ALLOC_NTAVM in lj_alloc.c).
 * iOS maps nothing below 4 GB, so luaL_newstate() returns NULL and the host
 * program crashes on its first Lua call. LOVE games (Balatro, ...) ship such a
 * lua51.dll.
 *
 * create_mapping() asks madeira_luajit_compat_fd() about every image section.
 * For an x64 DLL that exports luaJIT_setmode and contains the string
 * "NtAllocateVirtualMemory" -- only builds with LJ_ALLOC_NTAVM do -- it returns
 * an fd of the GC64 build in the app bundle (build/luajit-x64/build.sh), and
 * the section is created from that file instead. The game's file on disk is
 * never touched. Detection is by content, not by file or program name.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define LJC_MAX_SCAN   (16u << 20)   /* a LuaJIT DLL is well under 1 MB */
#define LJC_MAX_NAMES  4096

static int ljc_read( int fd, void *buf, size_t len, off_t pos )
{
    return pread( fd, buf, len, pos ) == (ssize_t)len;
}

static uint16_t ljc_u16( const unsigned char *p ) { return p[0] | p[1] << 8; }
static uint32_t ljc_u32( const unsigned char *p ) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

/* File offset of an RVA, from the section table; -1 if it is in no section. */
static off_t ljc_rva_to_off( const unsigned char *secs, unsigned int nsec, uint32_t rva )
{
    unsigned int i;

    for (i = 0; i < nsec; i++)
    {
        const unsigned char *s = secs + i * 40;
        uint32_t vsize = ljc_u32( s + 8 ), va = ljc_u32( s + 12 );
        uint32_t rawsize = ljc_u32( s + 16 ), rawptr = ljc_u32( s + 20 );
        uint32_t size = vsize > rawsize ? vsize : rawsize;
        if (rva >= va && rva - va < size && rva - va < rawsize) return (off_t)rawptr + (rva - va);
    }
    return -1;
}

/* Does this x64 PE export luaJIT_setmode? The export name table is sorted, so
 * a binary search reads about a dozen names. */
static int ljc_exports_luajit( int fd )
{
    static const char want[] = "luaJIT_setmode";
    unsigned char mz[64], nt[24 + 240], secs[96 * 40], exp[40];
    unsigned int nsec, opt_size, lo, hi;
    uint32_t lfanew, exp_rva, names_rva;
    off_t exp_off, names_off;

    if (!ljc_read( fd, mz, sizeof(mz), 0 ) || mz[0] != 'M' || mz[1] != 'Z') return 0;
    lfanew = ljc_u32( mz + 0x3c );
    if (!ljc_read( fd, nt, sizeof(nt), lfanew )) return 0;
    if (memcmp( nt, "PE\0\0", 4 ) || ljc_u16( nt + 4 ) != 0x8664) return 0;   /* x64 only */
    nsec = ljc_u16( nt + 6 );
    opt_size = ljc_u16( nt + 20 );
    if (ljc_u16( nt + 24 ) != 0x20b || opt_size < 112 + 8 || !nsec || nsec > 96) return 0;
    exp_rva = ljc_u32( nt + 24 + 112 );                   /* DataDirectory[0] */
    if (!exp_rva) return 0;
    if (!ljc_read( fd, secs, nsec * 40, lfanew + 24 + opt_size )) return 0;

    if ((exp_off = ljc_rva_to_off( secs, nsec, exp_rva )) < 0 || !ljc_read( fd, exp, sizeof(exp), exp_off ))
        return 0;
    hi = ljc_u32( exp + 24 );                              /* NumberOfNames */
    names_rva = ljc_u32( exp + 32 );                       /* AddressOfNames */
    if (!hi || hi > LJC_MAX_NAMES || (names_off = ljc_rva_to_off( secs, nsec, names_rva )) < 0) return 0;

    for (lo = 0; lo < hi;)
    {
        unsigned int mid = lo + (hi - lo) / 2;
        unsigned char rva_buf[4];
        char name[sizeof(want)] = {0};
        off_t name_off;
        int cmp;

        if (!ljc_read( fd, rva_buf, 4, names_off + mid * 4 )) return 0;
        if ((name_off = ljc_rva_to_off( secs, nsec, ljc_u32( rva_buf ) )) < 0) return 0;
        if (pread( fd, name, sizeof(name) - 1, name_off ) <= 0) return 0;
        cmp = strncmp( name, want, sizeof(want) );   /* name holds at most strlen(want) chars */
        if (!cmp)
        {
            char next = 0;   /* a longer name with the same prefix is not a match */
            if (pread( fd, &next, 1, name_off + sizeof(want) - 1 ) == 1 && next) cmp = 1;
            else return 1;
        }
        if (cmp < 0) lo = mid + 1;
        else hi = mid;
    }
    return 0;
}

static int ljc_contains( int fd, off_t file_size, const char *needle )
{
    size_t nlen = strlen( needle );
    char *buf;
    int found = 0;

    if (file_size <= 0 || file_size > LJC_MAX_SCAN || !(buf = malloc( file_size ))) return 0;
    if (ljc_read( fd, buf, file_size, 0 )) found = memmem( buf, file_size, needle, nlen ) != NULL;
    free( buf );
    return found;
}

int madeira_luajit_compat_fd( int unix_fd, off_t file_size )
{
    const char *bundle = getenv( "WINEDLLPATH" );
    char path[4096];
    int fd;

    if (!ljc_exports_luajit( unix_fd )) return -1;
    if (!ljc_contains( unix_fd, file_size, "NtAllocateVirtualMemory" ))
    {
        fprintf( stderr, "[luajit-compat] x64 LuaJIT with GC64, left as is\n" );
        return -1;
    }
    if (!bundle || snprintf( path, sizeof(path), "%s/compat/love/lua51.dll", bundle ) >= (int)sizeof(path))
        return -1;
    if ((fd = open( path, O_RDONLY | O_CLOEXEC )) == -1)
    {
        fprintf( stderr, "[luajit-compat] x64 LuaJIT needs memory below 2 GB, but %s is missing\n", path );
        return -1;
    }
    fprintf( stderr, "[luajit-compat] x64 LuaJIT needs memory below 2 GB; mapping the bundled GC64 build instead\n" );
    return fd;
}
