/* OpenGL: DXT (S3TC) textures must sample on a GPU without BC formats.
 *
 * Metal on A-series iPhones and iPads has no BC sampling, so Zink sees no
 * DXT formats. Mesa then exposes GL_EXT_texture_compression_s3tc only with
 * allow_compressed_fallback, which OSMesa left off until
 * build/mesa-ios/patches/0009: glCompressedTexImage2D failed with
 * GL_INVALID_ENUM, and a game's DXT textures drew black (Mewgenics, #566).
 *
 * Uploads one solid-green 4x4 block as DXT1 and as DXT5, draws each with
 * GL_REPLACE over a red clear and a blue vertex colour, and reads one pixel
 * back: green = the texture sampled; blue = the texture was incomplete, so
 * fixed function drew without it (a shader samples such a texture as black).
 *
 * Writes gls3tc-result.txt next to the exe. Exit code 0 = pass.
 * Build: tests/x64/build.sh gls3tc-x64 (link -lopengl32 -lgdi32 -luser32)
 */
#include <windows.h>
#include <GL/gl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define GL_COMPRESSED_RGB_S3TC_DXT1_EXT 0x83F0
#define GL_COMPRESSED_RGBA_S3TC_DXT5_EXT 0x83F3
typedef void (APIENTRY *compressed_tex_image_2d_fn)(GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLsizei,
                                                    const void *);

static FILE *out;
static void say(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    if (out) { va_start(ap, fmt); vfprintf(out, fmt, ap); va_end(ap); fflush(out); }
}

/* One 4x4 block, every texel colour0 = RGB565 0x07e0 (pure green). DXT5 adds
 * an alpha block with alpha0 = alpha1 = 255 and every index 0. */
static const unsigned char dxt1_green[8] = { 0xe0, 0x07, 0xe0, 0x07, 0, 0, 0, 0 };
static const unsigned char dxt5_green[16] = { 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0xe0, 0x07, 0x00, 0x00, 0, 0, 0, 0 };

static int draw_and_check(compressed_tex_image_2d_fn upload, GLenum format, const void *data, GLsizei size,
                          const char *name)
{
    GLuint tex = 0;
    unsigned char px[4] = {0};
    GLenum err;

    while (glGetError() != GL_NO_ERROR) {}
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    upload(GL_TEXTURE_2D, 0, format, 4, 4, 0, size, data);
    err = glGetError();

    glViewport(0, 0, 64, 64);
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_TEXTURE_2D);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    glColor3f(0, 0, 1);
    glBegin(GL_QUADS);
    glTexCoord2f(0, 0); glVertex2f(-1, -1);
    glTexCoord2f(1, 0); glVertex2f(1, -1);
    glTexCoord2f(1, 1); glVertex2f(1, 1);
    glTexCoord2f(0, 1); glVertex2f(-1, 1);
    glEnd();
    glDisable(GL_TEXTURE_2D);
    glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glDeleteTextures(1, &tex);

    int green = px[0] < 32 && px[1] > 224 && px[2] < 32;
    say("%s %s: upload error 0x%x, pixel %u,%u,%u (%s)\n", green ? "PASSED" : "FAILED", name, err, px[0], px[1],
        px[2], green ? "the texture sampled" : "blue: the texture was incomplete");
    return green;
}

int main(void)
{
    char path[MAX_PATH], *slash;
    GetModuleFileNameA(NULL, path, sizeof(path));
    if ((slash = strrchr(path, '\\'))) strcpy(slash + 1, "gls3tc-result.txt");
    out = fopen(path, "w");

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "gls3tc";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("gls3tc", "gls3tc", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 256, 256,
                              NULL, NULL, wc.hInstance, NULL);
    HDC dc = GetDC(hwnd);
    PIXELFORMATDESCRIPTOR pfd = { sizeof(pfd), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
                                  PFD_TYPE_RGBA, 32 };
    SetPixelFormat(dc, ChoosePixelFormat(dc, &pfd), &pfd);
    HGLRC rc = wglCreateContext(dc);
    if (!rc || !wglMakeCurrent(dc, rc)) { say("FAIL: no OpenGL context\n"); return 2; }
    say("GL_VERSION %s\n", (const char *)glGetString(GL_VERSION));
    say("GL_RENDERER %s\n", (const char *)glGetString(GL_RENDERER));

    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    int has_s3tc = ext && strstr(ext, "GL_EXT_texture_compression_s3tc") != NULL;
    say("GL_EXT_texture_compression_s3tc %s\n", has_s3tc ? "listed" : "MISSING");

    compressed_tex_image_2d_fn upload = (compressed_tex_image_2d_fn)wglGetProcAddress("glCompressedTexImage2D");
    if (!upload) { say("FAIL: glCompressedTexImage2D missing\n"); return 2; }

    int ok = draw_and_check(upload, GL_COMPRESSED_RGB_S3TC_DXT1_EXT, dxt1_green, sizeof(dxt1_green), "DXT1");
    ok &= draw_and_check(upload, GL_COMPRESSED_RGBA_S3TC_DXT5_EXT, dxt5_green, sizeof(dxt5_green), "DXT5");
    SwapBuffers(dc);
    Sleep(1000);

    say("RESULT %s\n", ok && has_s3tc ? "pass" : "fail (exit 1)");
    if (out) fclose(out);
    return ok && has_s3tc ? 0 : 1;
}
