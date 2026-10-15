/* Thin reservations (build/ntdll-unix/virtual_ios.c, ios_thin_reserve).
 *
 * Reserves many 1 GB read-write ranges and commits a little of each, the way
 * some games do, then checks that:
 *   - every reservation succeeds (more than the ~64 GB a device can map),
 *   - committed memory of different reservations never aliases,
 *   - VirtualQuery reports the untouched part as reserved (just past a head:
 *     reserved by its own reservation; further in, a thin tail may overlap a
 *     later head, so only "not free" is checked there),
 *   - MEM_DECOMMIT of the whole range and MEM_RELEASE succeed,
 *   - released space is reused,
 *   - growing one range past its head fails cleanly (prints where).
 *
 * Writes thinreserve-result.txt next to the exe. Exit code 0 = pass.
 * Build: tests/x64/build.sh thinreserve-x64 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define COUNT 80
#define GB    (1024ull * 1024 * 1024)
#define MB    (1024ull * 1024)

static FILE *out;
static int failures;

static void say( const char *fmt, ... )
{
    va_list ap;
    va_start( ap, fmt );
    vprintf( fmt, ap );
    va_end( ap );
    if (out)
    {
        va_start( ap, fmt );
        vfprintf( out, fmt, ap );
        va_end( ap );
        fflush( out );
    }
}

static void check( int ok, const char *what, int i )
{
    if (ok) return;
    failures++;
    say( "FAIL %s (reservation %d, error %lu)\n", what, i, GetLastError() );
}

int main( void )
{
    static char *base[COUNT];
    char path[MAX_PATH], *slash;
    MEMORY_BASIC_INFORMATION mbi;
    int i, n = 0;
    unsigned long long grown;

    GetModuleFileNameA( NULL, path, sizeof(path) );
    if ((slash = strrchr( path, '\\' ))) strcpy( slash + 1, "thinreserve-result.txt" );
    out = fopen( path, "w" );

    /* 1. reserve, commit 4 MB at the start and 64 KB at +16 MB, write a tag */
    for (i = 0; i < COUNT; i++)
    {
        base[i] = VirtualAlloc( NULL, GB, MEM_RESERVE, PAGE_READWRITE );
        if (!base[i]) break;
        n++;
        check( VirtualAlloc( base[i], 4 * MB, MEM_COMMIT, PAGE_READWRITE ) == base[i], "commit 4 MB", i );
        check( VirtualAlloc( base[i] + 16 * MB, 64 * 1024, MEM_COMMIT, PAGE_READWRITE ) != NULL,
               "commit at +16 MB", i );
        memset( base[i], 0x40 + (i & 0x3f), 4 * MB );
        memset( base[i] + 16 * MB, 0x80 + (i & 0x3f), 64 * 1024 );
    }
    say( "reserved %d of %d x 1 GB (%d GB)\n", n, COUNT, n );
    check( n == COUNT, "reserve all", n );

    /* 2. no aliasing: every tag is still intact */
    for (i = 0; i < n; i++)
    {
        unsigned long long k;
        int bad = 0;
        for (k = 0; k < 4 * MB; k += 4096) if (base[i][k] != (char)(0x40 + (i & 0x3f))) bad = 1;
        for (k = 0; k < 64 * 1024; k += 4096) if (base[i][16 * MB + k] != (char)(0x80 + (i & 0x3f))) bad = 1;
        check( !bad, "data intact", i );
    }

    /* 3. queries */
    for (i = 0; i < n; i++)
    {
        check( VirtualQuery( base[i], &mbi, sizeof(mbi) ) && mbi.State == MEM_COMMIT &&
               mbi.AllocationBase == base[i], "query committed start", i );
        /* A thin tail overlaps later heads, so +512 MB may report another
         * reservation; it must never report free. */
        check( VirtualQuery( base[i] + 512 * MB, &mbi, sizeof(mbi) ) && mbi.State != MEM_FREE,
               "query +512 MB is not free", i );
        /* Just past a 63 MB head is the guard: reserved, and ours. */
        check( VirtualQuery( base[i] + 63 * MB + 512 * 1024, &mbi, sizeof(mbi) ) &&
               mbi.State == MEM_RESERVE && mbi.AllocationBase == base[i],
               "query just past the head is our reservation", i );
    }

    /* 4. grow the last one in 1 MB steps up to 256 MB; report where it stops */
    for (grown = 4 * MB; grown < 256 * MB; grown += MB)
        if (!VirtualAlloc( base[n - 1] + grown, MB, MEM_COMMIT, PAGE_READWRITE )) break;
    say( "last reservation grew to %llu MB (thin heads stop just under the slot size; "
         "a normal reservation reaches 256)\n", grown / MB );
    check( grown >= 32 * MB, "growth of at least 32 MB", n - 1 );

    /* 5. decommit the whole range, then release */
    for (i = 0; i < n; i++)
    {
        check( VirtualFree( base[i], GB, MEM_DECOMMIT ), "decommit whole range", i );
        check( VirtualFree( base[i], 0, MEM_RELEASE ), "release", i );
    }

    /* 6. released space is reused */
    for (i = 0; i < n; i++)
    {
        base[i] = VirtualAlloc( NULL, GB, MEM_RESERVE, PAGE_READWRITE );
        check( base[i] != NULL, "reserve again after release", i );
    }
    for (i = 0; i < n; i++) if (base[i]) VirtualFree( base[i], 0, MEM_RELEASE );

    say( "%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures );
    if (out) fclose( out );
    return failures ? 1 : 0;
}
