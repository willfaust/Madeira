// SPDX-License-Identifier: GPL-3.0-or-later
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>
#include "manifest.h"

int wmain(void) {
    WCHAR path[32768];
    DWORD n = GetModuleFileNameW(NULL, path, 32768);
    if (!n || n >= 32700) return 1;
    WCHAR *name = wcsrchr(path, L'\\');
    if (!name) return 1;
    wcscpy(name + 1, L"madeira-gog-launch.bin");
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) return 2;
    DWORD size = GetFileSize(file, NULL), read = 0;
    if (size > 4 * 1024 * 1024 || size < 4) { CloseHandle(file); return 2; }
    unsigned char *bytes = malloc(size);
    int ok = bytes && ReadFile(file, bytes, size, &read, NULL) && read == size;
    CloseHandle(file);
    if (!ok) { free(bytes); return 2; }
    *name = 0;
    if (!SetCurrentDirectoryW(path)) { free(bytes); return 2; }
    const unsigned char *p = bytes;
    size_t left = size;
    uint32_t count;
    if (!gog_number(&p, &left, &count) || !count || count > 128) { free(bytes); return 2; }
    // Validate the complete file before running any setup.
    const unsigned char *check = p; size_t remaining = left;
    for (uint32_t i = 0; i < count * 4; i++) {
        const uint16_t *value;
        if (!gog_string(&check, &remaining, &value)) { free(bytes); return 2; }
    }
    if (remaining) { free(bytes); return 2; }
    WCHAR *extra = GetCommandLineW();
    if (*extra == L'"') { extra++; while (*extra && *extra != L'"') extra++; if (*extra) extra++; }
    else { while (*extra && *extra != L' ') extra++; }
    while (*extra == L' ') extra++;
    DWORD result = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint16_t *exe, *args, *marker, *directory;
        gog_string(&p, &left, &exe); gog_string(&p, &left, &args); gog_string(&p, &left, &marker); gog_string(&p, &left, &directory);
        int last = i + 1 == count;
        if (!last && *marker && GetFileAttributesW((LPCWSTR)marker) != INVALID_FILE_ATTRIBUTES) continue;
        WCHAR absolute[32768];
        if (!SetCurrentDirectoryW(path)) { result = GetLastError(); break; }
        DWORD length = GetFullPathNameW((LPCWSTR)exe, 32768, absolute, NULL);
        if (!length || length >= 32768 || (*directory && !SetCurrentDirectoryW((LPCWSTR)directory))) { result = 3; break; }
        size_t capacity = wcslen((LPCWSTR)exe) + wcslen((LPCWSTR)args) + (last ? wcslen(extra) : 0) + 8;
        if (capacity > 32767) { result = 3; break; }
        WCHAR *line = malloc(capacity * sizeof(WCHAR));
        if (!line) { result = 3; break; }
        swprintf(line, capacity, L"\"%ls\" %ls %ls", (LPCWSTR)exe, (LPCWSTR)args, last ? extra : L"");
        STARTUPINFOW startup = { sizeof(startup) }; PROCESS_INFORMATION process = {0};
        ok = CreateProcessW(absolute, line, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process);
        free(line);
        if (!ok) { result = GetLastError(); break; }
        CloseHandle(process.hThread);
        WaitForSingleObject(process.hProcess, INFINITE);
        GetExitCodeProcess(process.hProcess, &result); CloseHandle(process.hProcess);
        if (result && (last || result != 3010 && result != 1641)) break;
        if (!last && *marker) {
            HANDLE done = CreateFileW((LPCWSTR)marker, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
            if (done == INVALID_HANDLE_VALUE) { result = GetLastError(); break; }
            CloseHandle(done);
        }
    }
    free(bytes);
    return (int)result;
}
