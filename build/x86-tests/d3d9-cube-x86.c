/* Acceptance test PE for the WoW64 (i386) Direct3D 9 path (docs/WOW64.md).
 *
 * A 32-bit PE that spins a solid colour cube through a real D3D9 device and
 * exits with a known status.  It is deliberately the smallest program that
 * still exercises every part of the 32-bit graphics boundary we care about:
 *
 *   - a 32-bit process loading an i386 d3d9.dll and reaching its unix side
 *     through the WoW64 unix-call table,
 *   - a swapchain bound to a real HWND, so presentation has to find its way
 *     out to the app's Metal layer,
 *   - a DYNAMIC vertex buffer in D3DPOOL_DEFAULT that the guest Lock()s and
 *     writes through a 32-bit pointer every frame.  That last one is the
 *     interesting case: the pointer Lock() hands back must be INSIDE the
 *     pseudo-process's guest window, because this code stores it in a 32-bit
 *     register and dereferences it.  A host pointer would fault immediately.
 *
 * Deliberate restrictions:
 *   - No CRT.  This file supplies its own PE entry point (`start`, which the
 *     i386 Windows C ABI mangles to `_start`) and its own memset/memcpy, and
 *     is linked -nostdlib, so the only imports are kernel32, user32 and
 *     d3d9 -- all Wine-supplied.  Verified with objdump -p in the build
 *     script.  Nothing here depends on ucrtbase/msvcrt plumbing.
 *   - No libm.  The two rotation angles are driven by wall-clock time (see
 *     below) rather than frame count, which needs cos/sin of an arbitrary,
 *     growing angle -- sinf_approx()/cosf_approx() below hand-roll that with
 *     a range reduction and a fixed-degree Taylor polynomial, so there is
 *     still no runtime libm call or float-library dependency, just inline
 *     arithmetic the compiler emits itself.
 *   - Wall-clock rotation, frame-rate independent.  QueryPerformanceCounter/
 *     QueryPerformanceFrequency (kernel32) give elapsed seconds since start;
 *     each rotor's angle is elapsed_seconds * a fixed rad/s rate, so the cube
 *     turns at the same visual speed whether the app is capped at 30, 60 or
 *     uncapped at whatever fps.  ll_to_double() below converts the 64-bit
 *     counter deltas to double using only 32-bit-to-double conversions and a
 *     float divide -- both single native instructions -- because -nostdlib
 *     leaves no compiler-rt/libgcc to satisfy a __divdi3/__floatdidf style
 *     helper call that a direct 64-bit int-to-float cast or a 64-bit integer
 *     divide might otherwise lower to.
 *   - FVF XYZRHW|DIFFUSE with software vertex processing: vertices are
 *     already in screen space when they reach the device, so the test needs
 *     no transform, lighting or texture state, and no fixed-function vertex
 *     pipeline beyond the bare minimum.
 *   - Hardware back-face culling.  All 12 triangles of the cube are submitted
 *     every frame; D3DRS_CULLMODE is D3DCULL_CCW (the Direct3D 9 default), so
 *     it is the driver's cull-state mapping that rejects the far faces, not
 *     CPU-side logic.  The `tri[]` index order in build_frame() reverses each
 *     quad's diagonal split relative to the `face[]` table's CCW-from-outside
 *     authoring, so that front faces come out clockwise in screen space --
 *     D3D9's front-facing convention under D3DCULL_CCW.  A cube is convex, so
 *     that alone gives a correct image with no depth buffer: exactly the
 *     (up to three) near faces survive culling.  Z test/write stays off by
 *     default (D3DRS_ZENABLE = D3DZB_FALSE); build with
 *     -DMADEIRA_D3D9_ZENABLE=1 to flip it on and exercise the depth path
 *     instead (a matching depth-stencil surface is then created and cleared).
 *
 * Exit status (reported by the runtime as "MADEIRA-EXIT: ... status=<n>"):
 *   43  success -- ran for MADEIRA_D3D9_SECONDS seconds of wall-clock time,
 *       or the window was closed after at least one frame was presented
 *   20  Direct3DCreate9 returned NULL
 *   21  CreateDevice failed
 *   22  CreateVertexBuffer failed
 *   23  Lock failed
 *   24  Present failed and the device never came back
 *   25  window creation failed
 *   26  the window was closed before any frame was presented
 */
#include <stddef.h>
#include <windows.h>
#include <d3d9.h>

#define MADEIRA_D3D9_SECONDS  15
#define WIN_W                 640
#define WIN_H                 480

/* Off by default: flip with -DMADEIRA_D3D9_ZENABLE=1 to exercise the depth
 * path instead of relying purely on D3DRS_CULLMODE (see the header comment
 * and the SetRenderState/Clear calls in start() below). */
#ifndef MADEIRA_D3D9_ZENABLE
#define MADEIRA_D3D9_ZENABLE 0
#endif

/* -nostdlib: clang may still lower a struct initialisation to a memset or
 * memcpy call, so provide them rather than hoping it does not. */
void *memset( void *dst, int c, size_t n )
{
    unsigned char *p = dst;
    while (n--) *p++ = (unsigned char)c;
    return dst;
}

void *memcpy( void *dst, const void *src, size_t n )
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

/* ---------------------------------------------------------------- logging */

static void out_str( const char *s )
{
    DWORD written = 0;
    const char *e = s;
    while (*e) e++;
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), s, (DWORD)(e - s), &written, NULL );
}

static char *put_uint( char *p, unsigned int v )
{
    char tmp[16];
    int n = 0;
    if (!v) { *p++ = '0'; return p; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    return p;
}

static char *put_hex( char *p, unsigned int v )
{
    static const char digits[] = "0123456789abcdef";
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    return p;
}

/* Prints a non-negative float with a fixed number of decimal digits, rounded
 * to nearest -- no CRT snprintf/dtoa available. */
static char *put_fixed( char *p, float v, int decimals )
{
    unsigned int scale = 1;
    unsigned int scaled, whole, frac, d;
    int i;

    if (v < 0.0f) v = 0.0f;
    for (i = 0; i < decimals; i++) scale *= 10;
    scaled = (unsigned int)(v * (float)scale + 0.5f);
    whole  = scaled / scale;
    frac   = scaled % scale;

    p = put_uint( p, whole );
    *p++ = '.';
    d = scale / 10;
    while (d)
    {
        *p++ = (char)('0' + (frac / d) % 10);
        d /= 10;
    }
    return p;
}

static void log_step( const char *what, unsigned int hr )
{
    char buf[128];
    char *p = buf;
    const char *s = "MADEIRA-D3D9: ";
    while (*s) *p++ = *s++;
    while (*what) *p++ = *what++;
    *p++ = ' ';
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* One line per presented frame for the first few frames: the frame number and
 * the HRESULT Present actually returned.  `frame N` below is only printed once
 * Present has already succeeded, so it cannot show a Present that returned a
 * failure code or one that never returned at all. */
static void log_present( unsigned int frame, unsigned int hr )
{
    char buf[96];
    char *p = buf;
    const char *s = "MADEIRA-D3D9: present ";
    while (*s) *p++ = *s++;
    p = put_uint( p, frame );
    *p++ = ' '; *p++ = 'h'; *p++ = 'r'; *p++ = '=';
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_frame( unsigned int frame )
{
    char buf[64];
    char *p = buf;
    const char *s = "MADEIRA-D3D9: frame ";
    while (*s) *p++ = *s++;
    p = put_uint( p, frame );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------- cube model */

struct vertex           /* D3DFVF_XYZRHW | D3DFVF_DIFFUSE */
{
    float    x, y, z, rhw;
    D3DCOLOR color;
};

#define FVF_CUBE (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)

/* Unit cube corners, and the six faces as CCW quads seen from outside. */
static const float corner[8][3] =
{
    { -1, -1, -1 }, {  1, -1, -1 }, {  1,  1, -1 }, { -1,  1, -1 },
    { -1, -1,  1 }, {  1, -1,  1 }, {  1,  1,  1 }, { -1,  1,  1 },
};

static const int face[6][4] =
{
    { 0, 1, 2, 3 },   /* -Z */
    { 5, 4, 7, 6 },   /* +Z */
    { 4, 0, 3, 7 },   /* -X */
    { 1, 5, 6, 2 },   /* +X */
    { 4, 5, 1, 0 },   /* -Y */
    { 3, 2, 6, 7 },   /* +Y */
};

static const D3DCOLOR face_color[6] =
{
    0xffe04040, 0xff40e040, 0xff4040e0,
    0xffe0e040, 0xff40e0e0, 0xffe040e0,
};

/* ---------------------------------------------------------- trig, no libm */

#define MADEIRA_PI      3.14159265358979323846f
#define MADEIRA_TWO_PI  (2.0f * MADEIRA_PI)

/* Range-reduce x into [-PI, PI].  The float-to-int truncation is a native
 * cvttss2si/fistp instruction, not a runtime call. */
static float wrap_pi( float x )
{
    float k = (float)(int)(x * (1.0f / MADEIRA_TWO_PI));
    x -= k * MADEIRA_TWO_PI;
    if (x >  MADEIRA_PI) x -= MADEIRA_TWO_PI;
    if (x < -MADEIRA_PI) x += MADEIRA_TWO_PI;
    return x;
}

/* 7th-order Taylor sine/cosine over the reduced range: plenty accurate for a
 * spinning test cube, and no libm dependency -- just multiplies and adds. */
static float sinf_approx( float x )
{
    float x2;
    x = wrap_pi( x );
    x2 = x * x;
    return x * (1.0f + x2 * (-1.0f / 6.0f +
                    x2 * (1.0f / 120.0f +
                    x2 * (-1.0f / 5040.0f))));
}

static float cosf_approx( float x )
{
    return sinf_approx( x + MADEIRA_PI * 0.5f );
}

/* Angular rates matching the milestone's original per-frame steps (2*pi/180
 * and 2*pi/300 at an assumed 60 fps), but now expressed as rad/s so the
 * rotation is frame-rate independent. */
#define YAW_RATE_RAD_PER_SEC    (MADEIRA_TWO_PI / 3.0f)   /* full turn / 3s */
#define PITCH_RATE_RAD_PER_SEC  (MADEIRA_TWO_PI / 5.0f)   /* full turn / 5s */

/* Converts a 64-bit tick delta to a double using only 32-bit-to-double
 * conversions and 64-bit shifts/subtracts (all native, no compiler-rt call):
 * -nostdlib means a direct (double)(LONGLONG) cast or a 64-bit integer
 * divide could silently need a __floatdidf/__divdi3 helper we cannot link. */
static double ll_to_double( LONGLONG v )
{
    LONG  hi = (LONG)(v >> 32);
    DWORD lo = (DWORD)(v & 0xFFFFFFFFu);
    return (double)hi * 4294967296.0 + (double)lo;
}

/* ---------------------------------------------------------- cube geometry */

/* Fill `out` with all 12 triangles for this frame; returns the triangle
 * count (always 12).  Vertices come out already in screen space, which is
 * what XYZRHW means.  Back-face rejection is left entirely to the device's
 * D3DRS_CULLMODE now, so every triangle is submitted regardless of facing. */
static unsigned int build_frame( struct vertex *out,
                                 float ca, float sa, float cb, float sb,
                                 float width, float height )
{
    float sx[8], sy[8], sw[8];
    unsigned int tris = 0;
    const float cam_z = 4.5f;            /* camera distance along +Z   */
    const float focal = 0.9f * height;   /* pixels per unit at z = 1   */
    const float cx = width * 0.5f;
    const float cy = height * 0.5f;
    int i, f;

    for (i = 0; i < 8; i++)
    {
        float x = corner[i][0], y = corner[i][1], z = corner[i][2];
        float x1, y1, z1, z2, inv;

        /* yaw about Y, then pitch about X */
        x1 =  x * ca + z * sa;
        z1 = -x * sa + z * ca;
        y1 =  y * cb - z1 * sb;
        z2 =  y * sb + z1 * cb;

        z2 += cam_z;                     /* always >= ~2.7: cube half-
                                             diagonal < cam_z, no near clip */
        inv = 1.0f / z2;
        sx[i] = cx + focal * x1 * inv;
        sy[i] = cy - focal * y1 * inv;
        sw[i] = inv;
    }

    for (f = 0; f < 6; f++)
    {
        const int *q = face[f];
        /* Reversed relative to face[]'s CCW-from-outside quad authoring: a
         * quad (q0,q1,q2,q3) is split here as (q0,q2,q1) and (q0,q3,q2), the
         * mirror image of the natural (q0,q1,q2)/(q0,q2,q3) split.  That
         * makes front (camera-facing) triangles wind clockwise in screen
         * space, which is D3D9's front-facing convention under the default
         * D3DRS_CULLMODE = D3DCULL_CCW. */
        static const int tri[6] = { 0, 2, 1, 0, 3, 2 };
        int k;

        for (k = 0; k < 6; k++)
        {
            int c = q[tri[k]];
            out->x     = sx[c];
            out->y     = sy[c];
            out->z     = 0.5f;
            out->rhw   = sw[c];
            out->color = face_color[f];
            out++;
        }
        tris += 2;
    }
    return tris;
}

/* ------------------------------------------------------------------ window */

static volatile int window_closed;

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_CLOSE:
    case WM_DESTROY:
        window_closed = 1;
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void pump( void )
{
    MSG msg;
    while (PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE ))
    {
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
}

/* -------------------------------------------------------------------- main */

void start( void )
{
    WNDCLASSEXA wc;
    D3DPRESENT_PARAMETERS pp;
    HWND hwnd;
    HINSTANCE inst = GetModuleHandleA( NULL );
    IDirect3D9 *d3d;
    IDirect3DDevice9 *dev = NULL;
    IDirect3DVertexBuffer9 *vb = NULL;
    unsigned int frame, presented = 0;
    LARGE_INTEGER qpc_freq, qpc_start, qpc_now;
    double freq_d, total_elapsed_d;
    float total_elapsed, avg_fps;
    HRESULT hr;

    out_str( "MADEIRA-D3D9: 32-bit D3D9 cube starting\n" );

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.hCursor       = NULL;
    wc.lpszClassName = "MadeiraD3D9CubeX86";
    if (!RegisterClassExA( &wc ))
    {
        log_step( "RegisterClassExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }

    hwnd = CreateWindowExA( 0, wc.lpszClassName, "Madeira D3D9 cube (32-bit)",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            0, 0, WIN_W, WIN_H, NULL, NULL, inst, NULL );
    if (!hwnd)
    {
        log_step( "CreateWindowExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }
    log_step( "hwnd", (unsigned int)(ULONG_PTR)hwnd );

    d3d = Direct3DCreate9( D3D_SDK_VERSION );
    if (!d3d)
    {
        out_str( "MADEIRA-D3D9: Direct3DCreate9 returned NULL\n" );
        ExitProcess( 20 );
    }
    out_str( "MADEIRA-D3D9: Direct3DCreate9 ok\n" );

    memset( &pp, 0, sizeof(pp) );
    pp.Windowed               = TRUE;
    pp.SwapEffect             = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat       = D3DFMT_UNKNOWN;
    pp.BackBufferWidth        = WIN_W;
    pp.BackBufferHeight       = WIN_H;
    pp.hDeviceWindow          = hwnd;
#if MADEIRA_D3D9_ZENABLE
    pp.EnableAutoDepthStencil = TRUE;
    pp.AutoDepthStencilFormat = D3DFMT_D16;
#else
    pp.EnableAutoDepthStencil = FALSE;
#endif
    pp.PresentationInterval   = D3DPRESENT_INTERVAL_IMMEDIATE;

    hr = IDirect3D9_CreateDevice( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                  D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev );
    if (FAILED(hr) || !dev)
    {
        log_step( "CreateDevice failed, hr", (unsigned int)hr );
        ExitProcess( 21 );
    }
    out_str( "MADEIRA-D3D9: device created (software vertex processing)\n" );

    hr = IDirect3DDevice9_CreateVertexBuffer( dev, 12 * 3 * sizeof(struct vertex),
                                              D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY,
                                              FVF_CUBE, D3DPOOL_DEFAULT, &vb, NULL );
    if (FAILED(hr) || !vb)
    {
        log_step( "CreateVertexBuffer failed, hr", (unsigned int)hr );
        ExitProcess( 22 );
    }
    out_str( "MADEIRA-D3D9: dynamic vertex buffer created\n" );

    IDirect3DDevice9_SetRenderState( dev, D3DRS_LIGHTING, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ZENABLE,
                                     MADEIRA_D3D9_ZENABLE ? D3DZB_TRUE : D3DZB_FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_CULLMODE, D3DCULL_CCW );
    IDirect3DDevice9_SetFVF( dev, FVF_CUBE );

    {
        char buf[64];
        char *p = buf;
        const char *s = "MADEIRA-D3D9: cull=CCW z=";
        while (*s) *p++ = *s++;
        s = MADEIRA_D3D9_ZENABLE ? "on" : "off";
        while (*s) *p++ = *s++;
        s = " seconds=";
        while (*s) *p++ = *s++;
        p = put_uint( p, MADEIRA_D3D9_SECONDS );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }

    QueryPerformanceFrequency( &qpc_freq );
    QueryPerformanceCounter( &qpc_start );
    freq_d = ll_to_double( qpc_freq.QuadPart );

    for (frame = 0; ; frame++)
    {
        void *locked = NULL;
        unsigned int tris, clear_flags;
        float elapsed_seconds, angle_a, angle_b, ca, sa, cb, sb;

        pump();
        if (window_closed) break;

        QueryPerformanceCounter( &qpc_now );
        elapsed_seconds = (float)(ll_to_double( qpc_now.QuadPart - qpc_start.QuadPart ) / freq_d);
        if (elapsed_seconds >= (float)MADEIRA_D3D9_SECONDS) break;

        angle_a = elapsed_seconds * YAW_RATE_RAD_PER_SEC;
        angle_b = elapsed_seconds * PITCH_RATE_RAD_PER_SEC;
        ca = cosf_approx( angle_a ); sa = sinf_approx( angle_a );
        cb = cosf_approx( angle_b ); sb = sinf_approx( angle_b );

        hr = IDirect3DVertexBuffer9_Lock( vb, 0, 0, &locked, D3DLOCK_DISCARD );
        if (FAILED(hr) || !locked)
        {
            log_step( "Lock failed, hr", (unsigned int)hr );
            ExitProcess( 23 );
        }
        if (!frame) log_step( "first locked vertex pointer", (unsigned int)(ULONG_PTR)locked );

        tris = build_frame( locked, ca, sa, cb, sb, (float)WIN_W, (float)WIN_H );
        IDirect3DVertexBuffer9_Unlock( vb );

        clear_flags = D3DCLEAR_TARGET | (MADEIRA_D3D9_ZENABLE ? D3DCLEAR_ZBUFFER : 0);
        IDirect3DDevice9_Clear( dev, 0, NULL, clear_flags,
                                D3DCOLOR_XRGB( 24, 28, 40 ), 1.0f, 0 );
        if (SUCCEEDED(IDirect3DDevice9_BeginScene( dev )))
        {
            if (tris)
            {
                IDirect3DDevice9_SetStreamSource( dev, 0, vb, 0, sizeof(struct vertex) );
                hr = IDirect3DDevice9_DrawPrimitive( dev, D3DPT_TRIANGLELIST, 0, tris );
                if (!frame) log_step( "first DrawPrimitive returned hr", (unsigned int)hr );
            }
            IDirect3DDevice9_EndScene( dev );
        }

        hr = IDirect3DDevice9_Present( dev, NULL, NULL, NULL, NULL );
        if (frame < 3) log_present( frame + 1, (unsigned int)hr );
        if (FAILED(hr))
        {
            log_step( "Present failed, hr", (unsigned int)hr );
            if (hr == D3DERR_DEVICELOST || hr == D3DERR_DEVICENOTRESET)
            {
                Sleep( 50 );
                continue;
            }
            ExitProcess( 24 );
        }
        presented++;
        if (frame == 0 || frame == 1 || ((frame + 1) % 60) == 0) log_frame( frame + 1 );
    }

    QueryPerformanceCounter( &qpc_now );
    total_elapsed_d = ll_to_double( qpc_now.QuadPart - qpc_start.QuadPart ) / freq_d;
    total_elapsed   = (float)total_elapsed_d;
    avg_fps         = (total_elapsed > 0.0f) ? ((float)presented / total_elapsed) : 0.0f;

    if (vb)  IDirect3DVertexBuffer9_Release( vb );
    if (dev) IDirect3DDevice9_Release( dev );
    IDirect3D9_Release( d3d );
    DestroyWindow( hwnd );

    if (!presented)
    {
        out_str( "MADEIRA-D3D9: closed before any frame was presented\n" );
        ExitProcess( 26 );
    }

    {
        char buf[128];
        char *p = buf;
        const char *s = "MADEIRA-D3D9: done, frames presented = ";
        while (*s) *p++ = *s++;
        p = put_uint( p, presented );
        s = ", seconds = ";
        while (*s) *p++ = *s++;
        p = put_fixed( p, total_elapsed, 2 );
        s = ", avg fps = ";
        while (*s) *p++ = *s++;
        p = put_fixed( p, avg_fps, 1 );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }
    ExitProcess( 43 );
}
