/* iOS unix side for dlls/dnsapi/libresolv.c   (MADEIRA, 2026-09-15)
 *
 * WHY THIS EXISTS
 * ---------------
 * dnsapi.dll had NO unixlib on this port.  Its DllMain calls
 * __wine_init_unix_call() and, when that fails, prints "No libresolv support,
 * expect problems" and CARRIES ON: every DnsQuery_A / DnsQuery_W /
 * DnsFlushResolverCache path still expands RESOLV_CALL() -> WINE_UNIX_CALL() ->
 * __wine_unix_call(__wine_unixlib_handle=0, code, args).  On this port that
 * NULL handle was a host-side load through the dispatcher's
 * `ldr x16, [x0, x1, lsl #3]`, i.e. a read of address code*8 -- log n60 shows
 * addr=0x8 with x0=0 x1=1, then SEGV LOOP DETECTED and a dead pseudo-process,
 * for a 32-bit program that did nothing worse than initialise networking.
 * signal_arm64_ios.c's ios_unixlib_null_call() now makes that survivable for
 * ANY library; this file gives dnsapi a real unix side so it does not need it.
 *
 * SHAPE
 * -----
 * Same shape as dwrite_freetype_ios.c: keep upstream's file as the
 * implementation and rewrite only the way it reaches its host library.
 * Upstream dlls/dnsapi/libresolv.c calls res_init()/res_query() and touches
 * `_res` directly, expecting configure to have linked -lresolv.  Linking
 * -lresolv here would add a new dependency to the app's final link (which this
 * build stage does not own), so instead the three things it uses are resolved
 * at first use out of /usr/lib/libresolv.9.dylib with dlopen/dlsym -- a system
 * library, which is the one dlopen an iOS sandbox does allow.
 *
 * Every one of those has a no-libresolv fallback that RETURNS a failure rather
 * than faulting: no resolver library means DnsQuery_A reports
 * DNS_ERROR_RCODE_SERVER_FAILURE (via map_h_errno(TRY_AGAIN)) and the server
 * list comes back empty (DNS_ERROR_NO_DNS_SERVERS).  A DNS lookup that fails
 * is a normal, documented outcome for a Windows program; a process that dies
 * inside the lookup is not.
 *
 * Apple spellings this file relies on (iPhoneOS SDK <resolv.h>):
 *   res_init  -> res_9_init,  res_ninit -> res_9_ninit
 *   res_query -> res_9_query, res_nquery -> res_9_nquery
 *   __res_state (both the struct tag and the per-thread accessor)
 *                              -> __res_9_state
 * The _n* forms take the state explicitly and report through
 * state->res_h_errno, so they are preferred: they keep this file off the
 * process-global `_res`/`h_errno` symbols entirely.
 */

/* Wine's configure ran for macOS and its config.h does not turn this file on
 * (HAVE_RESOLV is what guards ALL of libresolv.c).  Enable it and the headers
 * it needs here, for this TU only. */
#undef HAVE_RESOLV
#define HAVE_RESOLV 1
#undef HAVE_RESOLV_H
#define HAVE_RESOLV_H 1
#undef HAVE_NETINET_IN_H
#define HAVE_NETINET_IN_H 1
#undef HAVE_ARPA_NAMESER_H
#define HAVE_ARPA_NAMESER_H 1
#undef HAVE_NETDB_H
#define HAVE_NETDB_H 1

/* Deliberately NOT enabled:
 *  - HAVE_RES_GETSERVERS would pull in res_9_getservers and a
 *    union res_sockaddr_union layout for one more dynamic symbol; the
 *    _res.nscount path below it needs nothing extra and reports the same
 *    IPv4 servers.
 *  - HAVE_STRUCT___RES_STATE__U__EXT_NSCOUNT6 would report IPv6 nameservers
 *    out of _u._ext.nsaddrs, which is only populated by res_ninit when the
 *    system resolver configuration lists any; leaving it off costs an IPv6-only
 *    setup its server list and costs a query nothing, because res_nquery uses
 *    the state's own servers either way. */
#undef HAVE_RES_GETSERVERS
#undef HAVE_STRUCT___RES_STATE__U__EXT_NSCOUNT6

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/nameser.h>
#include <resolv.h>
#include <netdb.h>

/***********************************************************************
 *           the libresolv binding
 */
static pthread_once_t ios_resolv_once = PTHREAD_ONCE_INIT;
static void *ios_resolv_lib;

static void ios_resolv_load(void)
{
    static const char * const paths[] =
    {
        "/usr/lib/libresolv.9.dylib",   /* iOS: in the dyld shared cache */
        "libresolv.9.dylib",
        "libresolv.dylib",
    };
    unsigned int i;

    for (i = 0; i < sizeof(paths) / sizeof(paths[0]) && !ios_resolv_lib; i++)
        ios_resolv_lib = dlopen( paths[i], RTLD_NOW | RTLD_LOCAL );

    /* dprintf, not ERR: the app runs with WINEDEBUG=err+all,err-virtual and
     * this line has to be readable in every log. */
    if (ios_resolv_lib)
        dprintf( STDERR_FILENO, "[unixlib] dnsapi: libresolv loaded (%p)\n", ios_resolv_lib );
    else
        dprintf( STDERR_FILENO, "[unixlib] dnsapi: NO libresolv on this device (%s) -- "
                 "queries will return DNS_ERROR_RCODE_SERVER_FAILURE\n", dlerror() );
}

static void *ios_resolv_sym( const char *name )
{
    pthread_once( &ios_resolv_once, ios_resolv_load );
    return ios_resolv_lib ? dlsym( ios_resolv_lib, name ) : NULL;
}

typedef struct __res_state *(*ios_res_state_fn)( void );
typedef int (*ios_res_ninit_fn)( struct __res_state * );
typedef int (*ios_res_nquery_fn)( struct __res_state *, const char *, int, int,
                                  unsigned char *, int );

/* Resolved once each; the racing initialisers below are benign (every racer
 * stores the same pointer, and a NULL read just repeats the dlsym). */
#define IOS_RESOLV_SYM( var, type, apple, posix )                       \
    static type var;                                                    \
    static int var##_done;                                              \
    if (!var##_done)                                                    \
    {                                                                   \
        if (!(var = (type)ios_resolv_sym( apple )))                     \
            var = (type)ios_resolv_sym( posix );                        \
        var##_done = 1;                                                 \
    }

/* h_errno: this file's own, so the TU never references the process-global one.
 * res_nquery reports through state->res_h_errno, which is copied here. */
static __thread int ios_resolv_h_errno;

/* Used only when libresolv is missing entirely: an all-zero state, whose
 * nscount is 0 (-> DNS_ERROR_NO_DNS_SERVERS) and whose options never gain
 * RES_INIT (-> init_resolver() keeps retrying the absent res_init, which is a
 * NULL check).  Shared by every thread on purpose: nothing ever writes a
 * meaningful value into it. */
static struct __res_state ios_resolv_null_state;

static struct __res_state *ios_resolv_state(void)
{
    IOS_RESOLV_SYM( p_state, ios_res_state_fn, "__res_9_state", "__res_state" )

    if (p_state)
    {
        struct __res_state *state = p_state();
        if (state) return state;
    }
    return &ios_resolv_null_state;
}

static int ios_resolv_init(void)
{
    struct __res_state *state = ios_resolv_state();

    if (state != &ios_resolv_null_state)
    {
        IOS_RESOLV_SYM( p_ninit, ios_res_ninit_fn, "res_9_ninit", "res_ninit" )
        if (p_ninit) return p_ninit( state );
    }
    ios_resolv_h_errno = TRY_AGAIN;
    return -1;
}

static int ios_resolv_query( const char *dname, int class, int type,
                             unsigned char *answer, int anslen )
{
    struct __res_state *state = ios_resolv_state();
    int ret;

    if (state != &ios_resolv_null_state)
    {
        IOS_RESOLV_SYM( p_nquery, ios_res_nquery_fn, "res_9_nquery", "res_nquery" )
        if (p_nquery)
        {
            ret = p_nquery( state, dname, class, type, answer, anslen );
            /* res_nquery reports the DNS-level failure here, and map_h_errno()
             * in libresolv.c is what turns it into a DNS_ERROR_RCODE_*. */
            if (ret < 0) ios_resolv_h_errno = state->res_h_errno;
            return ret;
        }
    }
    ios_resolv_h_errno = TRY_AGAIN;   /* -> DNS_ERROR_RCODE_SERVER_FAILURE */
    return -1;
}

/***********************************************************************
 *           upstream, with its three host-resolver references rewritten
 *
 * These have to come AFTER the definitions above, or the shims would rename
 * themselves.  <resolv.h> is already included, so the #include below sees only
 * its include guard and these macros survive.
 */
#undef res_init
#define res_init  ios_resolv_init
#undef res_query
#define res_query ios_resolv_query
#undef _res
#define _res      (*ios_resolv_state())
#undef h_errno
#define h_errno   ios_resolv_h_errno

#include "libresolv.c"
