/* LGPL-2.1-or-later: part of the Wine unix side (see docs/LICENSING.md). */
/*
 * winios OpenGL driver. Two backends, chosen at init by MADEIRA_GL_BACKEND
 * (set by WineProcessBridge.m from madeira.cfg `gl-backend`):
 *   zink - desktop OpenGL 3.3-4.x through Mesa OSMesa + Zink on MoltenVK
 *          (see the "zink backend" section below)
 *   gles - WGL on top of Apple's OpenGL ES 3.0 (EAGL), described here;
 *          also the fallback when Zink cannot start.
 *
 * iOS has no desktop OpenGL. What it has is OpenGL ES 3.0 through EAGL, which is
 * deprecated but still ships (iOS 27 SDK) and is what LOVE, SDL and most GLES
 * code on iOS target. This driver plugs it in behind win32u's WGL layer:
 *
 *  - Contexts are EAGLContexts (API 3, falling back to 2), created and made
 *    current by app/Madeira/Winios/WiniosGL.m. Every context is GLES whatever
 *    the app asked for, so an app that insists on desktop GL sees
 *    "OpenGL ES 3.0 ..." from glGetString and fails its own version check
 *    instead of crashing. LOVE is told to ask for GLES (WineProcessBridge.m).
 *  - EAGL has no window-system framebuffer: FBO 0 is not a surface. opengl32
 *    already emulates the default framebuffer with FBOs (drawable->draw_fbo /
 *    read_fbo + buffer_map), so each window drawable here is one FBO. GLES 3
 *    only allows COLOR_ATTACHMENTi in draw-buffer slot i, so instead of Wine's
 *    front/back attachment pairs every front/back/left buffer maps to
 *    COLOR_ATTACHMENT0; "swap" is then a copy of that attachment to the screen.
 *  - Present (swap, or a flush of front-buffer rendering) hands the FBO to
 *    WiniosGL.m, which blits it into an IOSurface and draws that onto the
 *    window's CAMetalLayer -- the same layer DXMT presents to.
 *  - Entry points come straight from OpenGLES.framework. Desktop-only GL 1.x
 *    functions that apps and opengl32 still call get small translations
 *    (glClearDepth, glDepthRange, glDrawBuffer, glGetDoublev) or a no-op stub,
 *    so a stray fixed-function call cannot jump through a NULL pointer.
 *
 * Not supported yet: pbuffers, multisampled pixel formats, desktop GL profiles.
 */

#if 0
#pragma makedep unix
#endif

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include "../madeira_cfg.h"   /* before Wine's headers, which poison strncpy */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach/mach_time.h>

#include "ntstatus.h"
#include "ntgdi_private.h"
#include "ntuser_private.h"
#include "win32u_private.h"
#include "wine/opengl_driver.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(wgl);

/* WiniosGL.m */
extern void *madeira_gl_context_create( void *share, int *major );
extern void madeira_gl_context_release( void *context );
extern int madeira_gl_make_current( void *context );
extern int madeira_gl_present( void **state, void *hwnd, unsigned int fbo, int width, int height );
extern void madeira_gl_present_release( void *state );
extern void madeira_gl_wait_active( void );
extern void *madeira_zink_target_bind( void **state, void *hwnd, int width, int height, int *row_pixels );
extern void *madeira_zink_target_present( void **state, void *hwnd, int *row_pixels );
extern void madeira_zink_target_release( void *state );

#define OPENGLES_PATH "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"

static void *gles_handle;

/* GLES entry points this driver calls itself. */
static void (*p_glGenFramebuffers)( GLsizei, GLuint * );
static void (*p_glDeleteFramebuffers)( GLsizei, const GLuint * );
static void (*p_glBindFramebuffer)( GLenum, GLuint );
static void (*p_glGenRenderbuffers)( GLsizei, GLuint * );
static void (*p_glDeleteRenderbuffers)( GLsizei, const GLuint * );
static void (*p_glBindRenderbuffer)( GLenum, GLuint );
static void (*p_glRenderbufferStorage)( GLenum, GLenum, GLsizei, GLsizei );
static void (*p_glFramebufferRenderbuffer)( GLenum, GLenum, GLenum, GLuint );
static GLenum (*p_glCheckFramebufferStatus)( GLenum );
static void (*p_glGetIntegerv)( GLenum, GLint * );
static void (*p_glGetFloatv)( GLenum, GLfloat * );
static void (*p_glClearDepthf)( GLfloat );
static void (*p_glDepthRangef)( GLfloat, GLfloat );
static void (*p_glDrawBuffers)( GLsizei, const GLenum * );

/* ---- pixel formats ---------------------------------------------------- */

struct ios_format
{
    BYTE depth;
    BYTE stencil;
    BOOL doublebuffer;
};

/* All RGBA8888. Double-buffered formats first: apps that walk the list take
 * the first acceptable one. */
static const struct ios_format ios_formats[] =
{
    { 24, 8, TRUE  },
    { 24, 0, TRUE  },
    { 16, 0, TRUE  },
    {  0, 0, TRUE  },
    { 24, 8, FALSE },
    {  0, 0, FALSE },
};

static const struct ios_format *format_from_index( int format )
{
    if (format < 1 || format > ARRAY_SIZE(ios_formats)) return NULL;
    return &ios_formats[format - 1];
}

static UINT ios_init_pixel_formats( UINT *onscreen_count )
{
    *onscreen_count = ARRAY_SIZE(ios_formats);
    return ARRAY_SIZE(ios_formats);
}

static BOOL ios_describe_pixel_format( int format, struct wgl_pixel_format *fmt )
{
    const struct ios_format *f = format_from_index( format );
    PIXELFORMATDESCRIPTOR *pfd = &fmt->pfd;

    if (!f) return FALSE;

    memset( fmt, 0, sizeof(*fmt) );
    pfd->nSize = sizeof(*pfd);
    pfd->nVersion = 1;
    pfd->dwFlags = PFD_SUPPORT_OPENGL | PFD_DRAW_TO_WINDOW | PFD_SUPPORT_COMPOSITION;
    if (f->doublebuffer) pfd->dwFlags |= PFD_DOUBLEBUFFER;
    pfd->iPixelType = PFD_TYPE_RGBA;
    pfd->iLayerType = PFD_MAIN_PLANE;
    pfd->cColorBits = 32;
    pfd->cRedBits = pfd->cGreenBits = pfd->cBlueBits = pfd->cAlphaBits = 8;
    pfd->cBlueShift = 0;
    pfd->cGreenShift = 8;
    pfd->cRedShift = 16;
    pfd->cAlphaShift = 24;
    pfd->cDepthBits = f->depth;
    pfd->cStencilBits = f->stencil;

    fmt->swap_method = WGL_SWAP_COPY_ARB;   /* swap copies the back buffer out, it survives */
    fmt->transparent = GL_FALSE;
    fmt->pixel_type = WGL_TYPE_RGBA_ARB;
    fmt->draw_to_pbuffer = GL_FALSE;
    fmt->transparent_alpha_value_valid = GL_TRUE;
    fmt->transparent_index_value_valid = GL_TRUE;
    fmt->sample_buffers = 0;
    fmt->samples = 0;
    fmt->framebuffer_srgb_capable = GL_FALSE;
    fmt->float_components = GL_FALSE;
    return TRUE;
}

static const char *ios_init_wgl_extensions( struct opengl_funcs *funcs )
{
    /* SDL only creates an OpenGL ES context through WGL when these are listed
     * (otherwise it goes looking for ANGLE's libEGL.dll). */
    return "WGL_EXT_create_context_es2_profile WGL_EXT_create_context_es_profile";
}

/* ---- entry points ----------------------------------------------------- */

static void WINAPI ios_glClearDepth( GLdouble depth )
{
    p_glClearDepthf( depth );
}

static void WINAPI ios_glDepthRange( GLdouble n, GLdouble f )
{
    p_glDepthRangef( n, f );
}

static void WINAPI ios_glDrawBuffer( GLenum buf )
{
    /* opengl32 has already mapped GL_BACK & co to COLOR_ATTACHMENT0 for the
     * default framebuffer; GLES 3 spells single draw buffers as a one-entry list. */
    p_glDrawBuffers( 1, &buf );
}

static void WINAPI ios_glGetDoublev( GLenum pname, GLdouble *data )
{
    GLfloat values[16];
    int count = 1;

    switch (pname)
    {
    case GL_VIEWPORT:
    case GL_SCISSOR_BOX:
    case GL_COLOR_CLEAR_VALUE:
    case GL_COLOR_WRITEMASK:
    case GL_BLEND_COLOR:
        count = 4;
        break;
    case GL_DEPTH_RANGE:
    case GL_ALIASED_LINE_WIDTH_RANGE:
    case GL_ALIASED_POINT_SIZE_RANGE:
    case GL_MAX_VIEWPORT_DIMS:
        count = 2;
        break;
    }
    p_glGetFloatv( pname, values );
    for (int i = 0; i < count; i++) data[i] = values[i];
}

/* GL 1.x functions GLES does not have (glBegin, glMatrixMode, ...). They are
 * part of opengl32's export table, so they must resolve to something. */
static INT_PTR WINAPI ios_gl_unsupported(void)
{
    static LONG warned;
    if (!InterlockedExchange( &warned, 1 ))
        ERR( "[winios-gl] a desktop-only OpenGL 1.x function was called; it does nothing on OpenGL ES\n" );
    return 0;
}

static const char *const gl_core_names[] =
{
#define USE_GL_FUNC(name) #name,
    ALL_GL_FUNCS
#undef USE_GL_FUNC
};

static BOOL is_gl_core_name( const char *name )
{
    for (UINT i = 0; i < ARRAY_SIZE(gl_core_names); i++)
        if (!strcmp( gl_core_names[i], name )) return TRUE;
    return FALSE;
}

static void *ios_get_proc_address( const char *name )
{
    void *ret;

    if (!strcmp( name, "glClearDepth" )) return ios_glClearDepth;
    if (!strcmp( name, "glDepthRange" )) return ios_glDepthRange;
    if (!strcmp( name, "glDrawBuffer" )) return ios_glDrawBuffer;
    if (!strcmp( name, "glGetDoublev" )) return ios_glGetDoublev;

    if ((ret = dlsym( gles_handle, name ))) return ret;
    if (is_gl_core_name( name )) return ios_gl_unsupported;
    return NULL;
}

/* ---- contexts --------------------------------------------------------- */

static BOOL ios_context_create( int format, void *share, const int *attribs, void **context )
{
    int major = 0, minor = 0, profile = 0, got = 0;

    for (; attribs && attribs[0]; attribs += 2)
    {
        switch (attribs[0])
        {
        case WGL_CONTEXT_MAJOR_VERSION_ARB: major = attribs[1]; break;
        case WGL_CONTEXT_MINOR_VERSION_ARB: minor = attribs[1]; break;
        case WGL_CONTEXT_PROFILE_MASK_ARB: profile = attribs[1]; break;
        }
    }

    if (!(*context = madeira_gl_context_create( share, &got )))
    {
        ERR( "[winios-gl] EAGLContext creation failed (format %d, share %p)\n", format, share );
        return FALSE;
    }

    ERR( "[winios-gl] context %p: OpenGL ES %d.0 for a %s %d.%d request (format %d, share %p)\n",
         *context, got, (profile & WGL_CONTEXT_ES2_PROFILE_BIT_EXT) ? "GLES" :
         (profile & WGL_CONTEXT_CORE_PROFILE_BIT_ARB) ? "desktop core" : "desktop",
         major, minor, format, share );
    return TRUE;
}

static BOOL ios_context_destroy( void *context )
{
    TRACE( "context %p\n", context );
    madeira_gl_context_release( context );
    return TRUE;
}

static BOOL ios_make_current( struct opengl_drawable *draw, struct opengl_drawable *read, void *context )
{
    TRACE( "draw %s, read %s, context %p\n", debugstr_opengl_drawable( draw ), debugstr_opengl_drawable( read ), context );
    return madeira_gl_make_current( context );
}

/* ---- window drawables ------------------------------------------------- */

struct ios_surface
{
    struct opengl_drawable base;
    void   *fbo_context;   /* EAGLContext the FBO lives in (FBOs are per context) */
    GLuint  color;         /* renderbuffers, shared across the sharegroup */
    GLuint  depth;
    int     width;
    int     height;
    void   *present_state; /* WiniosGL.m presenter */
};

static struct ios_surface *impl_from_drawable( struct opengl_drawable *base )
{
    return CONTAINING_RECORD( base, struct ios_surface, base );
}

static void drawable_client_size( struct opengl_drawable *drawable, int *width, int *height )
{
    HWND hwnd = drawable->client ? drawable->client->hwnd : 0;
    RECT rect = {0};

    if (hwnd) NtUserGetClientRect( hwnd, &rect, NtUserGetDpiForWindow( hwnd ) );
    *width = max( rect.right - rect.left, 1 );
    *height = max( rect.bottom - rect.top, 1 );
}

static void surface_client_size( struct ios_surface *surface, int *width, int *height )
{
    drawable_client_size( &surface->base, width, height );
}

static void surface_storage( struct ios_surface *surface, int width, int height )
{
    const struct ios_format *f = format_from_index( surface->base.format );
    GLint prev_rb = 0;

    p_glGetIntegerv( GL_RENDERBUFFER_BINDING, &prev_rb );
    p_glBindRenderbuffer( GL_RENDERBUFFER, surface->color );
    p_glRenderbufferStorage( GL_RENDERBUFFER, GL_RGBA8, width, height );
    if (surface->depth)
    {
        GLenum depth_format = f->stencil ? GL_DEPTH24_STENCIL8 :
                              f->depth == 16 ? GL_DEPTH_COMPONENT16 : GL_DEPTH_COMPONENT24;
        p_glBindRenderbuffer( GL_RENDERBUFFER, surface->depth );
        p_glRenderbufferStorage( GL_RENDERBUFFER, depth_format, width, height );
    }
    p_glBindRenderbuffer( GL_RENDERBUFFER, prev_rb );

    surface->width = width;
    surface->height = height;
    TRACE( "%s storage %dx%d\n", debugstr_opengl_drawable( &surface->base ), width, height );
}

static void surface_delete_objects( struct ios_surface *surface )
{
    if (surface->base.draw_fbo) p_glDeleteFramebuffers( 1, &surface->base.draw_fbo );
    if (surface->color) p_glDeleteRenderbuffers( 1, &surface->color );
    if (surface->depth) p_glDeleteRenderbuffers( 1, &surface->depth );
    surface->base.draw_fbo = surface->base.read_fbo = 0;
    surface->color = surface->depth = 0;
    surface->fbo_context = NULL;
}

/* Called with `context` current (or NULL while the old one is still current). */
static void ios_surface_set_context( struct opengl_drawable *base, void *context )
{
    struct ios_surface *surface = impl_from_drawable( base );
    const struct ios_format *f = format_from_index( base->format );
    GLint prev_draw = 0, prev_read = 0;
    GLenum status;
    int width, height;

    TRACE( "%s, context %p\n", debugstr_opengl_drawable( base ), context );

    if (!context)
    {
        /* win32u unsets drawables while their context is still current. */
        surface_delete_objects( surface );
        return;
    }
    if (surface->fbo_context == context && base->draw_fbo) return;
    if (surface->fbo_context)
    {
        /* Still owned by another context (another thread): deleting these names
         * here would hit whatever the current context calls them. Leak them. */
        WARN( "[winios-gl] %s moves from context %p to %p, dropping its framebuffer\n",
              debugstr_opengl_drawable( base ), surface->fbo_context, context );
        base->draw_fbo = base->read_fbo = 0;
        surface->color = surface->depth = 0;
    }

    p_glGetIntegerv( GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw );
    p_glGetIntegerv( GL_READ_FRAMEBUFFER_BINDING, &prev_read );

    p_glGenFramebuffers( 1, &base->draw_fbo );
    base->read_fbo = base->draw_fbo;
    p_glGenRenderbuffers( 1, &surface->color );
    if (f->depth || f->stencil) p_glGenRenderbuffers( 1, &surface->depth );

    surface_client_size( surface, &width, &height );
    surface_storage( surface, width, height );

    p_glBindFramebuffer( GL_FRAMEBUFFER, base->draw_fbo );
    p_glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, surface->color );
    if (surface->depth)
    {
        p_glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, surface->depth );
        if (f->stencil)
            p_glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, surface->depth );
    }
    status = p_glCheckFramebufferStatus( GL_FRAMEBUFFER );
    if (status != GL_FRAMEBUFFER_COMPLETE)
        ERR( "[winios-gl] %s: framebuffer incomplete %#x\n", debugstr_opengl_drawable( base ), status );

    p_glBindFramebuffer( GL_DRAW_FRAMEBUFFER, prev_draw );
    p_glBindFramebuffer( GL_READ_FRAMEBUFFER, prev_read );

    surface->fbo_context = context;
    ERR( "[winios-gl] %s: framebuffer %u %dx%d depth %u stencil %u in context %p\n",
         debugstr_opengl_drawable( base ), base->draw_fbo, width, height, f->depth, f->stencil, context );
}

static BOOL surface_present( struct ios_surface *surface )
{
    HWND hwnd = surface->base.client ? surface->base.client->hwnd : 0;

    if (!hwnd || !surface->base.draw_fbo) return FALSE;
    madeira_gl_wait_active();   /* no GPU work while the app is in the background */
    return madeira_gl_present( &surface->present_state, hwnd, surface->base.draw_fbo,
                               surface->width, surface->height );
}

static void ios_surface_flush( struct opengl_drawable *base, UINT flags )
{
    struct ios_surface *surface = impl_from_drawable( base );
    int width, height;

    TRACE( "%s, flags %#x\n", debugstr_opengl_drawable( base ), flags );

    if ((flags & GL_FLUSH_UPDATED) && base->draw_fbo)
    {
        surface_client_size( surface, &width, &height );
        if (width != surface->width || height != surface->height) surface_storage( surface, width, height );
    }
    if (flags & GL_FLUSH_PRESENT) surface_present( surface );
}

static BOOL ios_surface_swap( struct opengl_drawable *base )
{
    struct ios_surface *surface = impl_from_drawable( base );
    TRACE( "%s\n", debugstr_opengl_drawable( base ) );
    return surface_present( surface );
}

static void ios_surface_destroy( struct opengl_drawable *base )
{
    struct ios_surface *surface = impl_from_drawable( base );
    TRACE( "%s\n", debugstr_opengl_drawable( base ) );
    /* The GL objects went with set_context( NULL ); only the presenter is left. */
    if (surface->present_state) madeira_gl_present_release( surface->present_state );
}

static const struct opengl_drawable_funcs ios_surface_funcs =
{
    .destroy = ios_surface_destroy,
    .flush = ios_surface_flush,
    .swap = ios_surface_swap,
    .set_context = ios_surface_set_context,
};

static BOOL ios_surface_create( HWND hwnd, int format, struct opengl_drawable **drawable )
{
    struct client_surface *client;
    struct ios_surface *surface;

    TRACE( "hwnd %p, format %d\n", hwnd, format );

    if (!format_from_index( format )) return FALSE;
    if (!(client = nulldrv_client_surface_create( hwnd ))) return FALSE;
    surface = opengl_drawable_create( sizeof(*surface), &ios_surface_funcs, format, client );
    client_surface_release( client );
    if (!surface) return FALSE;

    /* One colour attachment backs every buffer name; see the file comment. */
    for (UINT i = 0; i < ARRAY_SIZE(surface->base.buffer_map); i++)
        surface->base.buffer_map[i] = GL_NONE;
    surface->base.buffer_map[GL_FRONT_LEFT - GL_FRONT_LEFT] = GL_COLOR_ATTACHMENT0;
    surface->base.buffer_map[GL_BACK_LEFT - GL_FRONT_LEFT] = GL_COLOR_ATTACHMENT0;
    surface->base.buffer_map[GL_FRONT - GL_FRONT_LEFT] = GL_COLOR_ATTACHMENT0;
    surface->base.buffer_map[GL_BACK - GL_FRONT_LEFT] = GL_COLOR_ATTACHMENT0;
    surface->base.buffer_map[GL_LEFT - GL_FRONT_LEFT] = GL_COLOR_ATTACHMENT0;
    surface->base.buffer_map[GL_FRONT_AND_BACK - GL_FRONT_LEFT] = GL_COLOR_ATTACHMENT0;

    ERR( "[winios-gl] window drawable %p for hwnd %p format %d\n", surface, hwnd, format );
    *drawable = &surface->base;
    return TRUE;
}

/* ---- pbuffers (not supported) ------------------------------------------ */

static BOOL ios_pbuffer_create( HDC hdc, int format, BOOL largest, GLenum texture_format, GLenum texture_target,
                                GLint max_level, GLsizei *width, GLsizei *height, struct opengl_drawable **drawable )
{
    FIXME( "[winios-gl] pbuffers are not supported (hdc %p, format %d, %dx%d)\n", hdc, format, *width, *height );
    return FALSE;
}

static BOOL ios_pbuffer_updated( HDC hdc, struct opengl_drawable *drawable, GLenum cube_face, GLint mipmap_level )
{
    return GL_TRUE;
}

static UINT ios_pbuffer_bind( HDC hdc, struct opengl_drawable *drawable, GLenum buffer )
{
    return -1; /* default implementation */
}

static const struct opengl_driver_funcs ios_driver_funcs =
{
    .p_get_proc_address = ios_get_proc_address,
    .p_init_pixel_formats = ios_init_pixel_formats,
    .p_describe_pixel_format = ios_describe_pixel_format,
    .p_init_wgl_extensions = ios_init_wgl_extensions,
    .p_surface_create = ios_surface_create,
    .p_context_create = ios_context_create,
    .p_context_destroy = ios_context_destroy,
    .p_make_current = ios_make_current,
    .p_pbuffer_create = ios_pbuffer_create,
    .p_pbuffer_updated = ios_pbuffer_updated,
    .p_pbuffer_bind = ios_pbuffer_bind,
};

/* ======================================================================
 * "zink" backend: desktop OpenGL 3.3-4.x through Mesa.
 *
 * Mesa's OSMesa frontend with the Zink driver (GL -> Vulkan), on MoltenVK
 * (Vulkan -> Metal); both dylibs ship in the bundle's gl/ folder
 * (build/mesa-ios/build.sh, build/moltenvk-ios/build.sh). OSMesa renders into
 * its own GPU texture and copies each finished frame, on glFlush/glFinish, into
 * a buffer we pass to OSMesaMakeCurrent: one of three IOSurfaces per window
 * (WiniosGL.m), which Metal then draws onto the window's layer. The default
 * framebuffer is OSMesa's own, so opengl32's FBO emulation stays off
 * (draw_fbo = 0). OSMesa visuals are single-buffered, so every BACK buffer
 * name maps to its FRONT twin; "swap" is glFinish + present + rebind.
 * ====================================================================== */

#define OSMESA_BGRA                  0x1
#define OSMESA_ROW_LENGTH            0x10
#define OSMESA_Y_UP                  0x11
#define OSMESA_FORMAT                0x22
#define OSMESA_DEPTH_BITS            0x30
#define OSMESA_STENCIL_BITS          0x31
#define OSMESA_ACCUM_BITS            0x32
#define OSMESA_PROFILE               0x33
#define OSMESA_CORE_PROFILE          0x34
#define OSMESA_COMPAT_PROFILE        0x35
#define OSMESA_CONTEXT_MAJOR_VERSION 0x36
#define OSMESA_CONTEXT_MINOR_VERSION 0x37

/* ---- perf line (zink backend), ml1340 ---------------------------------
 *
 * Once a second at most, from the thread that presents or makes a context
 * current, the zink backend logs
 *   [winios-gl] perf hwnd=H presents/s=N wgl-calls/s=N (32-bit thunk N)
 *               make-current/s=N flush-ms=N copy-ms=N over=Ss
 * presents:     frames handed to the window's layer
 * wgl-calls:    calls into this driver (make-current, flush, swap, contexts, drawables)
 * 32-bit thunk: GL/WGL calls of 32-bit programs through opengl32's wow64 thunks,
 *               every thread (dlls/opengl32/unix_private.h bumps the counter)
 * flush-ms:     ms per second in glFinish at present: Zink finishes the frame and
 *               OSMesa copies it into the IOSurface slot
 * copy-ms:      ms per second handing the slot to Metal and locking the next one
 *               (waits for Metal to release it) plus the OSMesa rebind
 * over:         the window the rates cover; longer than 1 s when nothing presents.
 * MADEIRA_GL_PERF=0 turns the counters and the line off. */

unsigned int madeira_gl_wow64_calls = 0;   /* weak in opengl32's unix_private.h */

static int gl_perf = -1;
static unsigned int perf_presents, perf_wgl_calls, perf_make_current, perf_wow64_mark;
static uint64_t perf_finish_ticks, perf_present_ticks, perf_window_start;
static mach_timebase_info_data_t perf_timebase;

static void stall_watch_start(void);

static void perf_init(void)
{
    const char *env = getenv( "MADEIRA_GL_PERF" );   /* 0: no GL perf line (presents/s, flush-ms ...) and no ml1341 stall reports */
    gl_perf = !(env && env[0] == '0');
    mach_timebase_info( &perf_timebase );
    ERR( "[winios-gl] ml1340 perf line %s (MADEIRA_GL_PERF)\n", gl_perf ? "on, once a second at most" : "off" );
    if (gl_perf) stall_watch_start();
}

static inline void perf_count( unsigned int *counter )
{
    if (gl_perf > 0) __atomic_fetch_add( counter, 1, __ATOMIC_RELAXED );
}

static inline uint64_t perf_now(void)
{
    return gl_perf > 0 ? mach_absolute_time() : 0;
}

static inline void perf_add_ticks( uint64_t *total, uint64_t start )
{
    if (gl_perf > 0) __atomic_fetch_add( total, mach_absolute_time() - start, __ATOMIC_RELAXED );
}

static double perf_ms( uint64_t ticks )
{
    return (double)ticks * perf_timebase.numer / perf_timebase.denom / 1e6;
}

static void perf_maybe_log( HWND hwnd )
{
    uint64_t now, start, finish, present;
    unsigned int presents, wgl, make_current, wow64;
    double secs;

    if (gl_perf <= 0) return;
    now = mach_absolute_time();
    start = __atomic_load_n( &perf_window_start, __ATOMIC_RELAXED );
    if (!start)
    {
        __atomic_compare_exchange_n( &perf_window_start, &start, now, FALSE, __ATOMIC_RELAXED, __ATOMIC_RELAXED );
        perf_wow64_mark = __atomic_load_n( &madeira_gl_wow64_calls, __ATOMIC_RELAXED );
        return;
    }
    if (perf_ms( now - start ) < 1000.0) return;
    /* one thread closes the window */
    if (!__atomic_compare_exchange_n( &perf_window_start, &start, now, FALSE, __ATOMIC_RELAXED, __ATOMIC_RELAXED ))
        return;

    secs = perf_ms( now - start ) / 1000.0;
    presents = __atomic_exchange_n( &perf_presents, 0, __ATOMIC_RELAXED );
    wgl = __atomic_exchange_n( &perf_wgl_calls, 0, __ATOMIC_RELAXED );
    make_current = __atomic_exchange_n( &perf_make_current, 0, __ATOMIC_RELAXED );
    finish = __atomic_exchange_n( &perf_finish_ticks, 0, __ATOMIC_RELAXED );
    present = __atomic_exchange_n( &perf_present_ticks, 0, __ATOMIC_RELAXED );
    wow64 = __atomic_load_n( &madeira_gl_wow64_calls, __ATOMIC_RELAXED );
    ERR( "[winios-gl] perf hwnd=%p presents/s=%.1f wgl-calls/s=%.0f (32-bit thunk %.0f) make-current/s=%.0f "
         "flush-ms=%.1f copy-ms=%.1f over=%.1fs\n", hwnd, presents / secs, wgl / secs,
         (wow64 - perf_wow64_mark) / secs, make_current / secs, perf_ms( finish ) / secs,
         perf_ms( present ) / secs, secs );
    perf_wow64_mark = wow64;
}

/* ---- stall reports (zink backend), ml1341 ------------------------------
 *
 * The perf line is written from the presenting thread, so it stops exactly
 * when a game stops presenting. A watcher thread reports such stalls:
 *   [winios-gl] ml1341 no GL present for N s (hwnd H): 32-bit GL calls since the last present A (B in the last C s)[; inside glFinish for D s]
 * at 5, 10, 20, 40 ... s, and the presenting thread writes
 *   [winios-gl] ml1341 presents resumed after N s
 * When B stays 0 the 32-bit caller (wined3d's command stream thread) is stuck
 * inside one GL call; when it grows, it is busy but not presenting. The
 * watcher is a plain pthread, so it writes with fprintf, not Wine's ERR.
 * Off with MADEIRA_GL_PERF=0. */

static uint64_t perf_last_present, perf_finish_start;
static unsigned int perf_wow64_at_present;
static HWND perf_last_hwnd;

/* ml1343: 32-bit GL calls per opengl32 wow64 thunk since the last present.
 * opengl32's get_teb64() passes the thunk's __func__ (a string literal, so
 * its address identifies the thunk); the slots are an open-addressed table
 * keyed by that address. A present bumps the epoch, which zeroes a slot the
 * next time it is counted. The stall report lists the top entries. */
#define GL_CALL_SLOTS 4096
struct gl_call_slot
{
    const char  *name;
    unsigned int epoch;
    unsigned int count;
};
static struct gl_call_slot gl_call_slots[GL_CALL_SLOTS];
static unsigned int gl_call_epoch = 1;

void madeira_gl_count_call( const char *thunk )   /* weak in opengl32's unix_private.h */
{
    unsigned int h, epoch, i;

    if (gl_perf <= 0 || !thunk) return;
    h = (unsigned int)(((uint64_t)(uintptr_t)thunk * 0x9e3779b97f4a7c15ull) >> 52);
    epoch = __atomic_load_n( &gl_call_epoch, __ATOMIC_RELAXED );
    for (i = 0; i < 32; i++)
    {
        struct gl_call_slot *s = &gl_call_slots[(h + i) & (GL_CALL_SLOTS - 1)];
        const char *cur = __atomic_load_n( &s->name, __ATOMIC_ACQUIRE );

        if (!cur)
        {
            const char *expected = NULL;
            if (__atomic_compare_exchange_n( &s->name, &expected, thunk, FALSE, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE ))
                cur = thunk;
            else
                cur = expected;
        }
        if (cur != thunk) continue;
        if (__atomic_load_n( &s->epoch, __ATOMIC_RELAXED ) != epoch)
        {
            __atomic_store_n( &s->epoch, epoch, __ATOMIC_RELAXED );
            __atomic_store_n( &s->count, 0, __ATOMIC_RELAXED );
        }
        __atomic_fetch_add( &s->count, 1, __ATOMIC_RELAXED );
        return;
    }
}

/* "wow64_ext_glFoo" -> "glFoo", "wow64_wgl_wglFoo" -> "wglFoo" */
static const char *gl_call_short_name( const char *name )
{
    const char *p = strstr( name, "_wgl" );
    if (!p) p = strstr( name, "_gl" );
    return p ? p + 1 : name;
}

/* Writes the ml1343 line: the top 12 thunks since the last present, and the
 * calls that wait for or read back the GPU. */
static void gl_call_report(void)
{
    static const struct { const char *label, *match; } waits[] =
    {
        { "finish", "_glFinish" }, { "flush", "_glFlush" }, { "fence", "_glFenceSync" },
        { "client-wait", "_glClientWaitSync" }, { "wait-sync", "_glWaitSync" }, { "get-sync", "_glGetSynciv" },
        { "get-query", "_glGetQueryObject" }, { "map", "_glMapBuffer" }, { "map-named", "_glMapNamedBuffer" },
        { "read-pixels", "_glReadPixels" }, { "get-teximage", "_glGetTexImage" },
    };
    unsigned int epoch = __atomic_load_n( &gl_call_epoch, __ATOMIC_RELAXED );
    unsigned int top_count[12] = {0}, wait_count[ARRAY_SIZE(waits)] = {0}, i, j, k, distinct = 0;
    const char *top_name[12] = {0};
    char line[4096];
    int len;

    for (i = 0; i < GL_CALL_SLOTS; i++)
    {
        const char *name = __atomic_load_n( &gl_call_slots[i].name, __ATOMIC_ACQUIRE );
        unsigned int count = __atomic_load_n( &gl_call_slots[i].count, __ATOMIC_RELAXED );

        if (!name || !count || __atomic_load_n( &gl_call_slots[i].epoch, __ATOMIC_RELAXED ) != epoch) continue;
        distinct++;
        for (k = 0; k < ARRAY_SIZE(waits); k++)
            if (strstr( name, waits[k].match )) wait_count[k] += count;
        for (j = 0; j < 12 && top_count[j] >= count; j++) ;
        if (j == 12) continue;
        memmove( top_count + j + 1, top_count + j, (11 - j) * sizeof(*top_count) );
        memmove( top_name + j + 1, top_name + j, (11 - j) * sizeof(*top_name) );
        top_count[j] = count;
        top_name[j] = name;
    }
    len = snprintf( line, sizeof(line), "[winios-gl] ml1343 32-bit GL calls since the last present (%u entry points):",
                    distinct );
    for (j = 0; j < 12 && top_name[j] && len < (int)sizeof(line) - 128; j++)
        len += snprintf( line + len, sizeof(line) - len, " %s %u", gl_call_short_name( top_name[j] ), top_count[j] );
    len += snprintf( line + len, sizeof(line) - len, " | waits:" );
    for (k = 0; k < ARRAY_SIZE(waits) && len < (int)sizeof(line) - 32; k++)
        len += snprintf( line + len, sizeof(line) - len, " %s %u", waits[k].label, wait_count[k] );
    fprintf( stderr, "%s\n", line );
}

static void *stall_watch( void *arg )
{
    uint64_t stall_ref = 0;
    unsigned int interval_mark = 0;
    double next = 5.0, last_report = 0.0;

    for (;;)
    {
        uint64_t last, finish_start, now;
        unsigned int wow64, since_present;
        double idle;

        sleep( 1 );
        if (!(last = __atomic_load_n( &perf_last_present, __ATOMIC_RELAXED ))) continue;
        now = mach_absolute_time();
        wow64 = __atomic_load_n( &madeira_gl_wow64_calls, __ATOMIC_RELAXED );
        if (last != stall_ref)
        {
            stall_ref = last;
            next = 5.0;
            last_report = 0.0;
            interval_mark = wow64;
            continue;
        }
        idle = perf_ms( now - last ) / 1000.0;
        if (idle < next) continue;

        since_present = wow64 - __atomic_load_n( &perf_wow64_at_present, __ATOMIC_RELAXED );
        finish_start = __atomic_load_n( &perf_finish_start, __ATOMIC_RELAXED );
        if (finish_start && finish_start < now)
            fprintf( stderr, "[winios-gl] ml1341 no GL present for %.0f s (hwnd %p): 32-bit GL calls since the last "
                     "present %u (%u in the last %.0f s); inside glFinish for %.1f s\n", idle, perf_last_hwnd,
                     since_present, wow64 - interval_mark, idle - last_report, perf_ms( now - finish_start ) / 1000.0 );
        else
            fprintf( stderr, "[winios-gl] ml1341 no GL present for %.0f s (hwnd %p): 32-bit GL calls since the last "
                     "present %u (%u in the last %.0f s)\n", idle, perf_last_hwnd, since_present,
                     wow64 - interval_mark, idle - last_report );
        gl_call_report();
        fflush( stderr );
        interval_mark = wow64;
        last_report = idle;
        next *= 2;
    }
    return NULL;
}

static void stall_watch_start(void)
{
    pthread_attr_t attr;
    pthread_t thread;

    pthread_attr_init( &attr );
    pthread_attr_setdetachstate( &attr, PTHREAD_CREATE_DETACHED );
    if (pthread_create( &thread, &attr, stall_watch, NULL ))
        ERR( "[winios-gl] ml1341 stall watcher did not start\n" );
    pthread_attr_destroy( &attr );
}

/* After a present: note it, and say so when it ends a stall the watcher reported. */
static void stall_presented( HWND hwnd )
{
    uint64_t now, prev;

    if (gl_perf <= 0) return;
    now = mach_absolute_time();
    prev = __atomic_exchange_n( &perf_last_present, now, __ATOMIC_RELAXED );
    __atomic_fetch_add( &gl_call_epoch, 1, __ATOMIC_RELAXED );   /* ml1343 counts restart */
    perf_last_hwnd = hwnd;
    __atomic_store_n( &perf_wow64_at_present, __atomic_load_n( &madeira_gl_wow64_calls, __ATOMIC_RELAXED ),
                      __ATOMIC_RELAXED );
    if (prev && perf_ms( now - prev ) >= 5000.0)
        ERR( "[winios-gl] ml1341 presents resumed after %.1f s\n", perf_ms( now - prev ) / 1000.0 );
}

static void *osmesa_handle;
static void *(*pOSMesaCreateContextAttribs)( const int *attribs, void *share );
static void (*pOSMesaDestroyContext)( void *ctx );
static GLboolean (*pOSMesaMakeCurrent)( void *ctx, void *buffer, GLenum type, GLsizei width, GLsizei height );
static void *(*pOSMesaGetCurrentContext)( void );
static void (*pOSMesaPixelStore)( GLint pname, GLint value );
static void *(*pOSMesaGetProcAddress)( const char *name );
static void (*pz_glFinish)( void );
static const GLubyte *(*pz_glGetString)( GLenum );

struct zink_surface
{
    struct opengl_drawable base;
    void *target;        /* WiniosGL.m IOSurface ring + presenter */
    int   width;
    int   height;
};

/* the drawable bound to this thread's current OSMesa context */
static __thread struct zink_surface *zink_current;

static struct zink_surface *zink_from_drawable( struct opengl_drawable *base )
{
    return CONTAINING_RECORD( base, struct zink_surface, base );
}

static HWND drawable_hwnd( struct opengl_drawable *drawable )
{
    return drawable->client ? drawable->client->hwnd : 0;
}

static const char *zink_init_wgl_extensions( struct opengl_funcs *funcs )
{
    return "";   /* desktop OpenGL only: no ES profiles */
}

static void *zink_get_proc_address( const char *name )
{
    return pOSMesaGetProcAddress( name );
}

static BOOL zink_context_create( int format, void *share, const int *attribs, void **context )
{
    const struct ios_format *f = format_from_index( format );
    int major = 0, minor = 0, profile = 0, a[20], n = 0;

    perf_count( &perf_wgl_calls );
    for (; attribs && attribs[0]; attribs += 2)
    {
        switch (attribs[0])
        {
        case WGL_CONTEXT_MAJOR_VERSION_ARB: major = attribs[1]; break;
        case WGL_CONTEXT_MINOR_VERSION_ARB: minor = attribs[1]; break;
        case WGL_CONTEXT_PROFILE_MASK_ARB: profile = attribs[1]; break;
        }
    }
    if (profile & WGL_CONTEXT_ES2_PROFILE_BIT_EXT)
    {
        ERR( "[winios-gl] zink: OpenGL ES %d.%d requested, only desktop OpenGL is available\n", major, minor );
        return FALSE;
    }

    a[n++] = OSMESA_FORMAT;       a[n++] = OSMESA_BGRA;
    a[n++] = OSMESA_DEPTH_BITS;   a[n++] = f ? f->depth : 24;
    a[n++] = OSMESA_STENCIL_BITS; a[n++] = f ? f->stencil : 8;
    a[n++] = OSMESA_ACCUM_BITS;   a[n++] = 0;
    a[n++] = OSMESA_PROFILE;
    a[n++] = (profile & WGL_CONTEXT_CORE_PROFILE_BIT_ARB) ? OSMESA_CORE_PROFILE : OSMESA_COMPAT_PROFILE;
    if (major)
    {
        a[n++] = OSMESA_CONTEXT_MAJOR_VERSION; a[n++] = major;
        a[n++] = OSMESA_CONTEXT_MINOR_VERSION; a[n++] = minor;
    }
    a[n] = 0;

    if (!(*context = pOSMesaCreateContextAttribs( a, share )))
    {
        ERR( "[winios-gl] zink: no context for a %s %d.%d request (format %d)\n",
             (profile & WGL_CONTEXT_CORE_PROFILE_BIT_ARB) ? "core" : "compatibility", major, minor, format );
        return FALSE;
    }
    ERR( "[winios-gl] zink: context %p for a %s %d.%d request (format %d, share %p)\n", *context,
         (profile & WGL_CONTEXT_CORE_PROFILE_BIT_ARB) ? "core" : "compatibility", major, minor, format, share );
    return TRUE;
}

static BOOL zink_context_destroy( void *context )
{
    perf_count( &perf_wgl_calls );
    pOSMesaDestroyContext( context );
    return TRUE;
}

/* Point OSMesa at `buffer` (the locked IOSurface slot) for `surface`. */
static BOOL zink_attach( struct zink_surface *surface, void *context, void *buffer, int row_pixels )
{
    if (!pOSMesaMakeCurrent( context, buffer, GL_UNSIGNED_BYTE, surface->width, surface->height )) return FALSE;
    pOSMesaPixelStore( OSMESA_ROW_LENGTH, row_pixels );
    pOSMesaPixelStore( OSMESA_Y_UP, 1 );   /* bottom row first, as the present shader expects */
    zink_current = surface;
    return TRUE;
}

static BOOL zink_bind( struct zink_surface *surface, void *context )
{
    int row = 0;
    void *buffer;

    drawable_client_size( &surface->base, &surface->width, &surface->height );
    if (!(buffer = madeira_zink_target_bind( &surface->target, drawable_hwnd( &surface->base ),
                                             surface->width, surface->height, &row )))
        return FALSE;
    return zink_attach( surface, context, buffer, row );
}

static BOOL zink_make_current( struct opengl_drawable *draw, struct opengl_drawable *read, void *context )
{
    TRACE( "draw %s, read %s, context %p\n", debugstr_opengl_drawable( draw ), debugstr_opengl_drawable( read ), context );

    perf_count( &perf_wgl_calls );
    perf_count( &perf_make_current );
    if (!context)
    {
        zink_current = NULL;
        return pOSMesaMakeCurrent( NULL, NULL, 0, 0, 0 );
    }
    if (!draw) return FALSE;
    perf_maybe_log( drawable_hwnd( draw ) );
    /* OSMesa has no separate read surface; reads come from the draw buffer. */
    return zink_bind( zink_from_drawable( draw ), context );
}

static BOOL zink_present( struct zink_surface *surface )
{
    void *context = pOSMesaGetCurrentContext(), *next;
    uint64_t start;
    BOOL ret;
    int row = 0;

    if (!context || zink_current != surface) return FALSE;
    madeira_gl_wait_active();   /* no GPU work while the app is in the background */
    start = perf_now();
    if (start) __atomic_store_n( &perf_finish_start, start, __ATOMIC_RELAXED );
    pz_glFinish();   /* OSMesa copies the frame into the locked IOSurface */
    if (start) __atomic_store_n( &perf_finish_start, 0, __ATOMIC_RELAXED );
    perf_add_ticks( &perf_finish_ticks, start );
    start = perf_now();
    if (!(next = madeira_zink_target_present( &surface->target, drawable_hwnd( &surface->base ), &row )))
        return FALSE;
    ret = zink_attach( surface, context, next, row );
    perf_add_ticks( &perf_present_ticks, start );
    stall_presented( drawable_hwnd( &surface->base ) );
    perf_count( &perf_presents );
    perf_maybe_log( drawable_hwnd( &surface->base ) );
    return ret;
}

static void zink_surface_flush( struct opengl_drawable *base, UINT flags )
{
    struct zink_surface *surface = zink_from_drawable( base );
    int width, height;

    TRACE( "%s, flags %#x\n", debugstr_opengl_drawable( base ), flags );

    perf_count( &perf_wgl_calls );
    if ((flags & GL_FLUSH_UPDATED) && zink_current == surface)
    {
        drawable_client_size( base, &width, &height );
        if (width != surface->width || height != surface->height)
            zink_bind( surface, pOSMesaGetCurrentContext() );
    }
    if (flags & GL_FLUSH_PRESENT) zink_present( surface );
}

static BOOL zink_surface_swap( struct opengl_drawable *base )
{
    TRACE( "%s\n", debugstr_opengl_drawable( base ) );
    perf_count( &perf_wgl_calls );
    return zink_present( zink_from_drawable( base ) );
}

static void zink_surface_destroy( struct opengl_drawable *base )
{
    struct zink_surface *surface = zink_from_drawable( base );
    perf_count( &perf_wgl_calls );
    if (zink_current == surface) zink_current = NULL;
    if (surface->target) madeira_zink_target_release( surface->target );
}

static const struct opengl_drawable_funcs zink_surface_funcs =
{
    .destroy = zink_surface_destroy,
    .flush = zink_surface_flush,
    .swap = zink_surface_swap,
};

static BOOL zink_surface_create( HWND hwnd, int format, struct opengl_drawable **drawable )
{
    struct client_surface *client;
    struct zink_surface *surface;

    perf_count( &perf_wgl_calls );
    if (!format_from_index( format )) return FALSE;
    if (!(client = nulldrv_client_surface_create( hwnd ))) return FALSE;
    surface = opengl_drawable_create( sizeof(*surface), &zink_surface_funcs, format, client );
    client_surface_release( client );
    if (!surface) return FALSE;

    /* Single-buffered OSMesa visual: back buffers are the front buffer. */
    surface->base.buffer_map[GL_BACK_LEFT - GL_FRONT_LEFT] = GL_FRONT_LEFT;
    surface->base.buffer_map[GL_BACK_RIGHT - GL_FRONT_LEFT] = GL_NONE;
    surface->base.buffer_map[GL_FRONT_RIGHT - GL_FRONT_LEFT] = GL_NONE;
    surface->base.buffer_map[GL_BACK - GL_FRONT_LEFT] = GL_FRONT;
    surface->base.buffer_map[GL_RIGHT - GL_FRONT_LEFT] = GL_NONE;
    surface->base.buffer_map[GL_FRONT_AND_BACK - GL_FRONT_LEFT] = GL_FRONT;

    ERR( "[winios-gl] zink: window drawable %p for hwnd %p format %d\n", surface, hwnd, format );
    *drawable = &surface->base;
    return TRUE;
}

static const struct opengl_driver_funcs zink_driver_funcs =
{
    .p_get_proc_address = zink_get_proc_address,
    .p_init_pixel_formats = ios_init_pixel_formats,
    .p_describe_pixel_format = ios_describe_pixel_format,
    .p_init_wgl_extensions = zink_init_wgl_extensions,
    .p_surface_create = zink_surface_create,
    .p_context_create = zink_context_create,
    .p_context_destroy = zink_context_destroy,
    .p_make_current = zink_make_current,
    .p_pbuffer_create = ios_pbuffer_create,
    .p_pbuffer_updated = ios_pbuffer_updated,
    .p_pbuffer_bind = ios_pbuffer_bind,
};

/* ---- shader disk cache (zink backend), ml1342 ---------------------------
 *
 * libOSMesa is built with Mesa's on-disk shader cache (build/mesa-ios/build.sh):
 * GLSL->NIR results, Zink's SPIR-V and its VkPipelineCache data persist, so a
 * second run converts far less (the Metal compile itself is then cached by
 * Metal). Mesa looks in $XDG_CACHE_HOME or $HOME/.cache; HOME is the Wine
 * prefix here, so point it at the app's Library/Caches instead, before the
 * dylib loads:
 *   <container>/Library/Caches/mesa-shader-cache/<libOSMesa LC_UUID>
 * Zink's cache key has no driver build id on Apple (no dl_iterate_phdr), so
 * entries written by an older libOSMesa would be reused by a newer one with
 * different shader passes; one directory per build avoids that, and the
 * directories of other builds are deleted. An existing MESA_SHADER_CACHE_DIR
 * is used as it is. Size limit MESA_SHADER_CACHE_MAX_SIZE, 256M unless set. */

static const char *shader_cache_prune_keep;
static uint64_t shader_cache_bytes;

static int shader_cache_sum( const char *path, const struct stat *st, int type, struct FTW *ftw )
{
    if (type == FTW_F) shader_cache_bytes += st->st_size;
    return 0;
}

static int shader_cache_rm( const char *path, const struct stat *st, int type, struct FTW *ftw )
{
    if (type == FTW_DP) rmdir( path );
    else unlink( path );
    return 0;
}

/* The LC_UUID of a thin arm64 Mach-O, as 32 hex digits. */
static BOOL macho_uuid( const char *path, char hex[33] )
{
    unsigned char buf[65536];
    unsigned int ncmds, off = 32, i;
    ssize_t len;
    int fd;

    if ((fd = open( path, O_RDONLY )) < 0) return FALSE;
    len = read( fd, buf, sizeof(buf) );
    close( fd );
    if (len < 32 || *(unsigned int *)buf != 0xfeedfacf) return FALSE;   /* MH_MAGIC_64 */
    ncmds = *(unsigned int *)(buf + 16);
    for (i = 0; i < ncmds && off + 8 <= (size_t)len; i++)
    {
        unsigned int cmd = *(unsigned int *)(buf + off), size = *(unsigned int *)(buf + off + 4);
        if (cmd == 0x1b && size >= 24 && off + 24 <= (size_t)len)   /* LC_UUID */
        {
            for (int b = 0; b < 16; b++) sprintf( hex + 2 * b, "%02x", buf[off + 8 + b] );
            return TRUE;
        }
        if (size < 8) break;
        off += size;
    }
    return FALSE;
}

static BOOL mkdir_p( char *path )
{
    for (char *p = path + 1; *p; p++)
    {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir( path, 0755 ) && errno != EEXIST) { *p = '/'; return FALSE; }
        *p = '/';
    }
    return !mkdir( path, 0755 ) || errno == EEXIST;
}

static void shader_cache_init( const char *osmesa_path )
{
    const char *off = getenv( "MADEIRA_GL_SHADER_CACHE" );   /* 0: no Mesa shader disk cache for desktop OpenGL (Zink); every run converts and compiles all shaders again */
    const char *dir = getenv( "MESA_SHADER_CACHE_DIR" ), *docs;
    char base[2048], path[2200], id[33] = "";
    struct dirent *de;
    DIR *d;

    if (off && off[0] == '0')
    {
        setenv( "MESA_SHADER_CACHE_DISABLE", "true", 1 );
        ERR( "[winios-gl] ml1342 shader cache off (MADEIRA_GL_SHADER_CACHE=0)\n" );
        return;
    }
    setenv( "MESA_SHADER_CACHE_MAX_SIZE", "256M", 0 );

    if (!dir || !*dir)
    {
        /* MADEIRA_DOCS_DIR is <container>/Documents (WineProcessBridge.m) */
        if ((docs = getenv( "MADEIRA_DOCS_DIR" )) && *docs && strlen( docs ) < sizeof(base) - 64)
        {
            char *slash;
            snprintf( base, sizeof(base), "%s", docs );
            if ((slash = strrchr( base, '/' ))) *slash = 0;
            strcat( base, "/Library/Caches/mesa-shader-cache" );
        }
        else if (confstr( _CS_DARWIN_USER_CACHE_DIR, base, sizeof(base) - 64 ))
            strcat( base, "/mesa-shader-cache" );
        else
        {
            ERR( "[winios-gl] ml1342 shader cache: no Caches directory, Mesa uses its default\n" );
            return;
        }
        if (!macho_uuid( osmesa_path, id )) strcpy( id, "unknown-build" );
        snprintf( path, sizeof(path), "%s/%s", base, id );
        if (!mkdir_p( path ))
        {
            ERR( "[winios-gl] ml1342 shader cache: cannot create %s (errno %d), Mesa uses its default\n", path, errno );
            return;
        }
        /* drop the caches of other libOSMesa builds */
        if ((d = opendir( base )))
        {
            char old[2200];
            while ((de = readdir( d )))
            {
                if (de->d_name[0] == '.' || !strcmp( de->d_name, id ) || strlen( de->d_name ) != 32 ||
                    strspn( de->d_name, "0123456789abcdef" ) != 32)
                    continue;
                snprintf( old, sizeof(old), "%s/%s", base, de->d_name );
                nftw( old, shader_cache_rm, 8, FTW_DEPTH | FTW_PHYS );
                ERR( "[winios-gl] ml1342 shader cache: removed the cache of an older build (%s)\n", de->d_name );
            }
            closedir( d );
        }
        setenv( "MESA_SHADER_CACHE_DIR", path, 1 );
        dir = getenv( "MESA_SHADER_CACHE_DIR" );
    }
    shader_cache_bytes = 0;
    nftw( dir, shader_cache_sum, 8, FTW_PHYS );
    ERR( "[winios-gl] ml1342 shader cache at %s (%llu MB used, limit %s; MADEIRA_GL_SHADER_CACHE=0 turns it off)\n",
         dir, (unsigned long long)((shader_cache_bytes + (1 << 19)) >> 20), getenv( "MESA_SHADER_CACHE_MAX_SIZE" ) );
}

/* Load OSMesa and prove Zink actually runs: a throwaway core-profile context
 * must report the Zink renderer. Mesa quietly falls back to softpipe when
 * Zink cannot start (no MoltenVK, missing Vulkan features), and a software
 * rasterizer is not an acceptable desktop-GL backend for games. */
static BOOL zink_init(void)
{
    static const int attribs[] = { OSMESA_FORMAT, OSMESA_BGRA, OSMESA_PROFILE, OSMESA_CORE_PROFILE,
                                   OSMESA_CONTEXT_MAJOR_VERSION, 3, OSMESA_CONTEXT_MINOR_VERSION, 3, 0 };
    const char *dir = getenv( "MADEIRA_GL_DIR" );
    const char *renderer, *version;
    char path[4096];
    unsigned int pixels[16];
    void *ctx;

    if (!dir || !*dir)
    {
        ERR( "[winios-gl] zink: MADEIRA_GL_DIR is not set\n" );
        return FALSE;
    }
    /* ml1344: the Vulkan driver under Zink. madeira.cfg `gl-vulkan = moltenvk |
     * kosmickrisp | <name or path>.dylib`, else env MADEIRA_GL_VULKAN; default
     * MoltenVK. KosmicKrisp (gl/libvulkan_kosmickrisp.dylib) exports
     * vkGetInstanceProcAddr itself (Mesa patch kosmickrisp-ios-0003), so Zink
     * can dlopen it like MoltenVK; Zink's Apple-only
     * VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR is ignored by Mesa's
     * Vulkan runtime, and VK_KHR_portability_enumeration is not requested (the
     * extension list is generated on the Linux build host). */
    {
        char want[1024] = "";
        const char *env;

        if ((!madeira_cfg_get( "gl-vulkan", want, sizeof(want) ) || !want[0]) &&
            (env = getenv( "MADEIRA_GL_VULKAN" )) && *env)   /* Vulkan driver for Zink when madeira.cfg gl-vulkan is unset: moltenvk (default), kosmickrisp, or a .dylib name/path */
            snprintf( want, sizeof(want), "%s", env );
        if (!want[0] || !strcasecmp( want, "moltenvk" ))
            snprintf( path, sizeof(path), "%s/libMoltenVK.dylib", dir );
        else if (!strcasecmp( want, "kosmickrisp" ))
            snprintf( path, sizeof(path), "%s/libvulkan_kosmickrisp.dylib", dir );
        else if (want[0] == '/')
            snprintf( path, sizeof(path), "%s", want );
        else
            snprintf( path, sizeof(path), "%s/%s", dir, want );
        if (access( path, R_OK ))
        {
            ERR( "[winios-gl] ml1344 zink Vulkan library %s not found (gl-vulkan = %s), using MoltenVK\n", path, want );
            snprintf( path, sizeof(path), "%s/libMoltenVK.dylib", dir );
        }
        ERR( "[winios-gl] ml1344 zink Vulkan library: %s\n", strrchr( path, '/' ) ? strrchr( path, '/' ) + 1 : path );
    }
    setenv( "ZINK_VULKAN_LIBRARY", path, 1 );
    setenv( "GALLIUM_DRIVER", "zink", 1 );
    setenv( "MVK_CONFIG_LOG_LEVEL", "1", 0 );   /* MoltenVK: errors only */
    /* ml1341: Zink on MoltenVK compiles each new pipeline synchronously (no
     * graphics pipeline libraries), and every GL thread that needs that
     * pipeline -- and, through Mesa's threaded-context syncs, any texture upload
     * -- waits for it. MoltenVK waits for a Metal compile forever by default, so
     * one compile the Metal compiler never finishes freezes the game for good.
     * Bound the wait: after MADEIRA_GL_COMPILE_TIMEOUT seconds (default 20) the
     * shader fails, MoltenVK logs "Timeout after ... Likely internal Metal
     * compiler error", keeps the failed library cached so it is not retried,
     * and Zink skips the draws that need it (patch 0004). 0 keeps MoltenVK's
     * default; an explicit env.MVK_CONFIG_METAL_COMPILE_TIMEOUT (ns) wins. */
    {
        const char *env = getenv( "MADEIRA_GL_COMPILE_TIMEOUT" );   /* seconds a Metal shader compile may take under Zink (default 20); then the shader fails and its draws are skipped. 0: no limit */
        long secs = env && *env ? strtol( env, NULL, 10 ) : 20;
        char ns[32];

        if (getenv( "MVK_CONFIG_METAL_COMPILE_TIMEOUT" ))
            ERR( "[winios-gl] ml1341 Metal compile timeout from MVK_CONFIG_METAL_COMPILE_TIMEOUT=%s ns\n",
                 getenv( "MVK_CONFIG_METAL_COMPILE_TIMEOUT" ) );
        else if (secs > 0)
        {
            snprintf( ns, sizeof(ns), "%lld", (long long)secs * 1000000000LL );
            setenv( "MVK_CONFIG_METAL_COMPILE_TIMEOUT", ns, 1 );
            ERR( "[winios-gl] ml1341 Metal compile timeout %ld s (MADEIRA_GL_COMPILE_TIMEOUT=0: MoltenVK's default, no limit)\n",
                 secs );
        }
        else ERR( "[winios-gl] ml1341 Metal compile timeout off (MADEIRA_GL_COMPILE_TIMEOUT=0)\n" );
    }
    /* Metal has no geometry shaders, so Zink on MoltenVK honestly reports at
     * most OpenGL 3.1 -- 3.2 core requires them -- and every 3.3 core request
     * fails. Advertise 4.1 (what macOS ships, what GL games target on Apple)
     * with GLSL 4.10, the same trade PojavLauncher makes on iOS: games that
     * never use geometry shaders run; one that does gets a shader or pipeline
     * error instead of no context at all. The override keeps each context's
     * profile ("X.Y" without FC/COMPAT). overwrite=0: madeira.cfg env.* lines
     * or the environment can set other values. Read once, at the first
     * context, so it has to be set here. */
    setenv( "MESA_GL_VERSION_OVERRIDE", "4.1", 0 );
    setenv( "MESA_GLSL_VERSION_OVERRIDE", "410", 0 );

    snprintf( path, sizeof(path), "%s/libOSMesa.dylib", dir );
    shader_cache_init( path );
    if (!(osmesa_handle = dlopen( path, RTLD_NOW | RTLD_LOCAL )))
    {
        ERR( "[winios-gl] zink: cannot load %s: %s\n", path, dlerror() );
        return FALSE;
    }
#define LOAD_FUNCPTR( name ) \
    if (!(p##name = dlsym( osmesa_handle, #name ))) \
    { \
        ERR( "[winios-gl] zink: %s missing from libOSMesa\n", #name ); \
        return FALSE; \
    }
    LOAD_FUNCPTR( OSMesaCreateContextAttribs );
    LOAD_FUNCPTR( OSMesaDestroyContext );
    LOAD_FUNCPTR( OSMesaMakeCurrent );
    LOAD_FUNCPTR( OSMesaGetCurrentContext );
    LOAD_FUNCPTR( OSMesaPixelStore );
    LOAD_FUNCPTR( OSMesaGetProcAddress );
#undef LOAD_FUNCPTR
    pz_glFinish = pOSMesaGetProcAddress( "glFinish" );
    pz_glGetString = pOSMesaGetProcAddress( "glGetString" );
    if (!pz_glFinish || !pz_glGetString) return FALSE;

    if (!(ctx = pOSMesaCreateContextAttribs( attribs, NULL )))
    {
        /* Say what Zink does offer: a plain compatibility context. */
        static const int compat[] = { OSMESA_FORMAT, OSMESA_BGRA, OSMESA_PROFILE, OSMESA_COMPAT_PROFILE, 0 };
        ERR( "[winios-gl] zink: 3.3 core test context failed (MESA_GL_VERSION_OVERRIDE=%s)\n",
             getenv( "MESA_GL_VERSION_OVERRIDE" ) );
        if (!(ctx = pOSMesaCreateContextAttribs( compat, NULL )))
        {
            ERR( "[winios-gl] zink: compatibility test context failed too\n" );
            return FALSE;
        }
    }
    if (!pOSMesaMakeCurrent( ctx, pixels, GL_UNSIGNED_BYTE, 4, 4 ))
    {
        ERR( "[winios-gl] zink: test context cannot be made current\n" );
        pOSMesaDestroyContext( ctx );
        return FALSE;
    }
    renderer = (const char *)pz_glGetString( GL_RENDERER );
    version = (const char *)pz_glGetString( GL_VERSION );
    ERR( "[winios-gl] zink: test context says %s | %s\n", renderer ? renderer : "(null)", version ? version : "(null)" );
    pOSMesaMakeCurrent( NULL, NULL, 0, 0, 0 );
    pOSMesaDestroyContext( ctx );

    if (!renderer || !strstr( renderer, "zink" ))
    {
        ERR( "[winios-gl] zink: renderer is not Zink (MoltenVK did not start?)\n" );
        return FALSE;
    }
    perf_init();
    return TRUE;
}

UINT winios_OpenGLInit( UINT version, const struct opengl_funcs *opengl_funcs,
                        const struct opengl_driver_funcs **driver_funcs )
{
    const char *backend = getenv( "MADEIRA_GL_BACKEND" );

    if (version != WINE_OPENGL_DRIVER_VERSION)
    {
        ERR( "[winios-gl] version mismatch, win32u wants %u but driver has %u\n", version, WINE_OPENGL_DRIVER_VERSION );
        return STATUS_INVALID_PARAMETER;
    }

    if (backend && !strcmp( backend, "zink" ))
    {
        if (zink_init())
        {
            ERR( "[winios-gl] desktop OpenGL (zink) driver ready (%u pixel formats)\n",
                 (UINT)ARRAY_SIZE(ios_formats) );
            *driver_funcs = &zink_driver_funcs;
            return STATUS_SUCCESS;
        }
        ERR( "[winios-gl] zink unavailable, falling back to OpenGL ES\n" );
    }

    if (!(gles_handle = dlopen( OPENGLES_PATH, RTLD_NOW )))
    {
        ERR( "[winios-gl] cannot load %s: %s\n", OPENGLES_PATH, dlerror() );
        return STATUS_NOT_SUPPORTED;
    }

#define LOAD_FUNCPTR( name ) \
    if (!(p_##name = dlsym( gles_handle, #name ))) \
    { \
        ERR( "[winios-gl] %s missing from OpenGLES\n", #name ); \
        return STATUS_NOT_SUPPORTED; \
    }
    LOAD_FUNCPTR( glGenFramebuffers );
    LOAD_FUNCPTR( glDeleteFramebuffers );
    LOAD_FUNCPTR( glBindFramebuffer );
    LOAD_FUNCPTR( glGenRenderbuffers );
    LOAD_FUNCPTR( glDeleteRenderbuffers );
    LOAD_FUNCPTR( glBindRenderbuffer );
    LOAD_FUNCPTR( glRenderbufferStorage );
    LOAD_FUNCPTR( glFramebufferRenderbuffer );
    LOAD_FUNCPTR( glCheckFramebufferStatus );
    LOAD_FUNCPTR( glGetIntegerv );
    LOAD_FUNCPTR( glGetFloatv );
    LOAD_FUNCPTR( glClearDepthf );
    LOAD_FUNCPTR( glDepthRangef );
    LOAD_FUNCPTR( glDrawBuffers );
#undef LOAD_FUNCPTR

    ERR( "[winios-gl] OpenGL ES driver ready (%u pixel formats)\n", (UINT)ARRAY_SIZE(ios_formats) );
    *driver_funcs = &ios_driver_funcs;
    return STATUS_SUCCESS;
}
