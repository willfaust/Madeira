/* OpenGL: a shader variable named like a Metal type must still compile.
 *
 * Draws a full-window quad whose fragment shader reads a multisample texture
 * through a uniform called "sampler" (a valid GLSL name, and Metal's sampler
 * type). Before build/mesa-ios/patches/0006 the Metal shader MoltenVK built
 * from it did not compile and Zink skipped the draw, so the window stayed at
 * the clear colour. Reads one pixel back: green = the draw ran.
 *
 * Writes glsampler-result.txt next to the exe. Exit code 0 = pass.
 * Build: tests/x64/build.sh glsampler-x64 (link -lopengl32 -lgdi32 -luser32)
 */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <string.h>

#define GL_FRAGMENT_SHADER 0x8B30
#define GL_VERTEX_SHADER 0x8B31
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_TEXTURE_2D_MULTISAMPLE 0x9100
#define GL_FRAMEBUFFER 0x8D40
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_RGBA8 0x8058
typedef char GLchar;
typedef GLuint (APIENTRY *create_shader_fn)(GLenum);
typedef void (APIENTRY *shader_source_fn)(GLuint, GLsizei, const GLchar *const *, const GLint *);
typedef void (APIENTRY *uint_fn)(GLuint);
typedef void (APIENTRY *get_iv_fn)(GLuint, GLenum, GLint *);
typedef void (APIENTRY *get_log_fn)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef GLuint (APIENTRY *create_program_fn)(void);
typedef void (APIENTRY *attach_fn)(GLuint, GLuint);
typedef GLint (APIENTRY *uniform_location_fn)(GLuint, const GLchar *);
typedef void (APIENTRY *uniform1i_fn)(GLint, GLint);
typedef void (APIENTRY *gen_fn)(GLsizei, GLuint *);
typedef void (APIENTRY *bind_fn)(GLenum, GLuint);
typedef void (APIENTRY *tex_ms_fn)(GLenum, GLsizei, GLenum, GLsizei, GLsizei, GLboolean);
typedef void (APIENTRY *fb_tex_fn)(GLenum, GLenum, GLenum, GLuint, GLint);
typedef GLenum (APIENTRY *fb_status_fn)(GLenum);
typedef void (APIENTRY *bind_vao_fn)(GLuint);

static FILE *out;
static void say(const char *fmt, const char *a, int b)
{
    printf(fmt, a, b);
    if (out) { fprintf(out, fmt, a, b); fflush(out); }
}
static void *proc(const char *name) { return (void *)wglGetProcAddress(name); }

static const char *vs =
    "#version 150\n"
    "void main() {\n"
    "    vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);\n"
    "    gl_Position = vec4(p, 0.0, 1.0);\n"
    "}\n";
static const char *fs =
    "#version 150\n"
    "uniform sampler2DMS sampler;\n"
    "out vec4 color;\n"
    "void main() { color = texelFetch(sampler, ivec2(0, 0), 0); }\n";

int main(void)
{
    char path[MAX_PATH], *slash, log[2048];
    GetModuleFileNameA(NULL, path, sizeof(path));
    if ((slash = strrchr(path, '\\'))) strcpy(slash + 1, "glsampler-result.txt");
    out = fopen(path, "w");

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "glsampler";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("glsampler", "glsampler", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 256, 256,
                              NULL, NULL, wc.hInstance, NULL);
    HDC dc = GetDC(hwnd);
    PIXELFORMATDESCRIPTOR pfd = { sizeof(pfd), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
                                  PFD_TYPE_RGBA, 32 };
    SetPixelFormat(dc, ChoosePixelFormat(dc, &pfd), &pfd);
    HGLRC rc = wglCreateContext(dc);
    if (!rc || !wglMakeCurrent(dc, rc)) { say("FAIL: no OpenGL context%s%d\n", "", 0); return 2; }
    say("GL_VERSION %s%d\n", (const char *)glGetString(GL_VERSION), 0);

    create_shader_fn glCreateShader = proc("glCreateShader");
    shader_source_fn glShaderSource = proc("glShaderSource");
    uint_fn glCompileShader = proc("glCompileShader"), glLinkProgram = proc("glLinkProgram"),
            glUseProgram = proc("glUseProgram");
    get_iv_fn glGetShaderiv = proc("glGetShaderiv"), glGetProgramiv = proc("glGetProgramiv");
    get_log_fn glGetShaderInfoLog = proc("glGetShaderInfoLog");
    create_program_fn glCreateProgram = proc("glCreateProgram");
    attach_fn glAttachShader = proc("glAttachShader");
    uniform_location_fn glGetUniformLocation = proc("glGetUniformLocation");
    uniform1i_fn glUniform1i = proc("glUniform1i");
    gen_fn glGenFramebuffers = proc("glGenFramebuffers"), glGenVertexArrays = proc("glGenVertexArrays");
    bind_fn glBindFramebuffer = proc("glBindFramebuffer");
    tex_ms_fn glTexImage2DMultisample = proc("glTexImage2DMultisample");
    fb_tex_fn glFramebufferTexture2D = proc("glFramebufferTexture2D");
    fb_status_fn glCheckFramebufferStatus = proc("glCheckFramebufferStatus");
    bind_vao_fn glBindVertexArray = proc("glBindVertexArray");
    if (!glCreateShader || !glTexImage2DMultisample || !glGenFramebuffers || !glBindVertexArray) {
        say("FAIL: GL 3.2 entry points missing%s%d\n", "", 0); return 2;
    }

    /* A 4x multisample texture cleared to green through a framebuffer. */
    GLuint tex = 0, fbo = 0, vao = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, tex);
    glTexImage2DMultisample(GL_TEXTURE_2D_MULTISAMPLE, 4, GL_RGBA8, 4, 4, GL_TRUE);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D_MULTISAMPLE, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { say("FAIL: MSAA framebuffer%s%d\n", "", 0); return 2; }
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    GLuint shaders[2] = { glCreateShader(GL_VERTEX_SHADER), glCreateShader(GL_FRAGMENT_SHADER) };
    const char *sources[2] = { vs, fs };
    GLuint program = glCreateProgram();
    for (int i = 0; i < 2; i++) {
        GLint ok = 0;
        glShaderSource(shaders[i], 1, &sources[i], NULL);
        glCompileShader(shaders[i]);
        glGetShaderiv(shaders[i], GL_COMPILE_STATUS, &ok);
        if (!ok) { glGetShaderInfoLog(shaders[i], sizeof(log), NULL, log); say("FAIL: GLSL compile: %s%d\n", log, 0); return 2; }
        glAttachShader(program, shaders[i]);
    }
    GLint linked = 0;
    glLinkProgram(program);
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) { say("FAIL: link%s%d\n", "", 0); return 2; }

    /* The window is cleared to red; the draw turns it green. */
    glViewport(0, 0, 64, 64);
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "sampler"), 0);
    glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    unsigned char px[4] = {0};
    glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    SwapBuffers(dc);
    Sleep(1000);

    int green = px[0] < 32 && px[1] > 224;
    char rgba[32];
    snprintf(rgba, sizeof(rgba), "%u,%u,%u", px[0], px[1], px[2]);
    say(green ? "PASSED: pixel %s is green (the draw ran), error=%d\n"
              : "FAILED: pixel %s is not green (the draw was skipped), error=%d\n", rgba, (int)glGetError());
    if (out) fclose(out);
    return green ? 0 : 1;
}
