// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
/* ml2320: C:\windows\system32\EpicGamesLauncher.exe. Madeira starts a game from its Epic library through
 * this program, so the game runs as the child of a process with the Epic client's name, as it does on
 * Windows. A publisher's launcher started by such a game looked for that process, did not find it and
 * treated the Epic copy as not owned (its store page offered the game for sale).
 *
 * Usage: EpicGamesLauncher.exe "<program>" [arguments]
 * The rest of the command line is started as it is, in this program's working folder and environment;
 * this program waits for it and exits with its exit code. It is not the Epic client: it opens no window,
 * signs in to nothing and makes no network connection. */
#include <windows.h>

int WINAPI wWinMain( HINSTANCE instance, HINSTANCE previous, WCHAR *command, int show )
{
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD code = 1;
    WCHAR *line;
    int length;

    (void)instance; (void)previous; (void)show;
    ZeroMemory( &startup, sizeof(startup) );
    startup.cb = sizeof(startup);
    while (*command == L' ' || *command == L'\t') command++;
    if (!(length = lstrlenW( command ))) return 1;
    /* CreateProcessW may write to its command line, so it gets a copy. */
    if (!(line = HeapAlloc( GetProcessHeap(), 0, (length + 1) * sizeof(WCHAR) ))) return 1;
    lstrcpyW( line, command );
    if (!CreateProcessW( NULL, line, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process )) return 1;
    CloseHandle( process.hThread );
    WaitForSingleObject( process.hProcess, INFINITE );
    GetExitCodeProcess( process.hProcess, &code );
    CloseHandle( process.hProcess );
    HeapFree( GetProcessHeap(), 0, line );
    return (int)code;
}
