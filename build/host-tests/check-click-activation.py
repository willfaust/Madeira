#!/usr/bin/env python3
"""Host-only regression check of the native click activation policy.

Extract the production helper and WM_MOUSEACTIVATE switch. Mock the window
server's foreground denial, keeping guest vetoes and failed activation intact.
No Wine runtime or guest executable is started.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/win32u-unix/message_ios.c').read_text()
helper = source[source.index('static BOOL ios_activate_clicked_window('):
                source.index('static BOOL process_mouse_message(')]
start = source.index('                switch(ret)', source.index('/* Activate the window if needed */'))
end = source.index('\n            }', start)
switch = source[start:end]

harness = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int BOOL;
typedef unsigned int UINT;
typedef unsigned int DWORD;
typedef void *HWND;
#define TRUE 1
#define FALSE 0
#define MA_ACTIVATE 1
#define MA_ACTIVATEANDEAT 2
#define MA_NOACTIVATE 3
#define MA_NOACTIVATEANDEAT 4
#define WARN(...) ((void)0)
static DWORD last_error;
static int calls, invalid_window, deny_foreground = 1;
static HWND active;
static DWORD RtlGetLastWin32Error(void) { return last_error; }
static void RtlSetLastWin32Error(DWORD e) { last_error = e; }
static HWND get_active_window(void) { return active; }
static HWND NtUserGetForegroundWindow(void) { return active; }
static BOOL set_foreground_window(HWND hwnd, BOOL mouse, BOOL internal)
{
    assert(mouse);
    ++calls;
    if (invalid_window || (deny_foreground && !internal))
    {
        last_error = invalid_window ? 1400 : 5;
        return FALSE;
    }
    active = hwnd;
    return TRUE;
}
'''
harness += helper
harness += '\nstatic BOOL dispatch(UINT ret) { HWND hwndTop=(HWND)0x1234; BOOL eat_msg=FALSE;\n'
harness += switch + '\nreturn !eat_msg; }\n'
harness += r'''
int main(void)
{
    for (deny_foreground = 0; deny_foreground <= 1; ++deny_foreground)
    for (invalid_window = 0; invalid_window <= 1; ++invalid_window)
    for (UINT reply = 0; reply <= 4; ++reply)
    {
        calls = 0; active = NULL; last_error = 123;
        BOOL delivered = dispatch(reply);
        BOOL activates = reply <= MA_ACTIVATEANDEAT;
        BOOL succeeds = activates && !deny_foreground && !invalid_window;
        BOOL eats = reply == MA_ACTIVATEANDEAT || reply == MA_NOACTIVATEANDEAT;
        assert(calls == activates);
        assert(!!active == succeeds);
        assert(delivered == (!eats && (!activates || succeeds)));
        assert(last_error == 123);
    }
    invalid_window = 0;
    deny_foreground = 0;
    assert(dispatch(MA_ACTIVATE));
    puts("PASS: foreground policy, explicit veto/eat, invalid window, and last-error preservation");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-click-check-') as directory:
    path = Path(directory)
    (path / 'check.c').write_text(harness)
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-o', str(path / 'check'),
                    str(path / 'check.c')], check=True)
    subprocess.run([str(path / 'check')], check=True)
