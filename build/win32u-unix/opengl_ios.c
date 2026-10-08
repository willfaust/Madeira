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
#include <pthread.h>

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

    if (!context)
    {
        zink_current = NULL;
        return pOSMesaMakeCurrent( NULL, NULL, 0, 0, 0 );
    }
    if (!draw) return FALSE;
    /* OSMesa has no separate read surface; reads come from the draw buffer. */
    return zink_bind( zink_from_drawable( draw ), context );
}

static BOOL zink_present( struct zink_surface *surface )
{
    void *context = pOSMesaGetCurrentContext(), *next;
    int row = 0;

    if (!context || zink_current != surface) return FALSE;
    madeira_gl_wait_active();   /* no GPU work while the app is in the background */
    pz_glFinish();   /* OSMesa copies the frame into the locked IOSurface */
    if (!(next = madeira_zink_target_present( &surface->target, drawable_hwnd( &surface->base ), &row )))
        return FALSE;
    return zink_attach( surface, context, next, row );
}

static void zink_surface_flush( struct opengl_drawable *base, UINT flags )
{
    struct zink_surface *surface = zink_from_drawable( base );
    int width, height;

    TRACE( "%s, flags %#x\n", debugstr_opengl_drawable( base ), flags );

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
    return zink_present( zink_from_drawable( base ) );
}

static void zink_surface_destroy( struct opengl_drawable *base )
{
    struct zink_surface *surface = zink_from_drawable( base );
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
    snprintf( path, sizeof(path), "%s/libMoltenVK.dylib", dir );
    setenv( "ZINK_VULKAN_LIBRARY", path, 1 );
    setenv( "GALLIUM_DRIVER", "zink", 1 );
    setenv( "MVK_CONFIG_LOG_LEVEL", "1", 0 );   /* MoltenVK: errors only */
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
