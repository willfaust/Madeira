#!/usr/bin/env python3
"""Run the production framebuffer cleanup with separate context namespaces."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/win32u-unix/opengl_ios.c').read_text()
a = source.index('static void surface_delete_objects(')
cleanup = source[a:source.index('\n}\n', a) + 3]
assert 'madeira_gl_context_retain( context );' in source
destroy = source[source.index('static void ios_surface_destroy('):]
assert 'surface_delete_objects( surface );' in destroy[:destroy.index('\n}')]
code = r'''
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
typedef unsigned GLuint;
struct context { int refs, busy, deleted; } first = {2}, second = {1};
static void *current = &second;
struct ios_surface { struct { GLuint draw_fbo, read_fbo; } base;
    void *fbo_context; GLuint color, depth; };
#define WARN(...) ((void)0)
static void *madeira_gl_context_current(void) { return current; }
static int madeira_gl_make_current(void *c)
{
    if (c && ((struct context *)c)->busy) return 0;
    current = c; return 1;
}
static void madeira_gl_context_release(void *c) { assert(--((struct context *)c)->refs >= 0); }
static void p_glDeleteFramebuffers(int n, const GLuint *id)
{ assert(n == 1 && *id == 7 && current == &first); first.deleted++; }
static void p_glDeleteRenderbuffers(int n, const GLuint *id)
{ assert(n == 1 && (*id == 8 || *id == 9) && current == &first); first.deleted++; }
CLEANUP
static struct ios_surface surface(void)
{
    struct ios_surface s = {{7,7}, &first, 8, 9}; return s;
}
int main(void)
{
    struct ios_surface s = surface();
    surface_delete_objects(&s);
    assert(current == &second && first.deleted == 3 && first.refs == 1);
    assert(!s.base.draw_fbo && !s.base.read_fbo && !s.color && !s.depth && !s.fbo_context);
    surface_delete_objects(&s);
    assert(first.deleted == 3 && first.refs == 1);
    first.refs++; current = &first; s = surface();
    surface_delete_objects(&s);
    assert(current == &first && first.deleted == 6 && first.refs == 1);
    first.refs++; first.busy = 1; current = &second; s = surface();
    surface_delete_objects(&s);
    assert(current == &second && first.deleted == 6 && first.refs == 1);
    assert(!s.fbo_context && !s.base.draw_fbo);
    puts("PASS: owner-context deletion, restored current context, retained lifetime and busy-owner safety");
}
'''.replace('CLEANUP', cleanup)
with tempfile.TemporaryDirectory() as folder:
    c = Path(folder) / 'test.c'
    binary = Path(folder) / 'test'
    c.write_text(code)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Werror', '-fsanitize=address,undefined',
                    str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
