/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 David Brookes
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#include <windows.h>
static unsigned text_length(const char *s) { unsigned n = 0; while (s[n]) ++n; return n; }
static int bytes_equal(const char *a, const char *b, unsigned n) { for (unsigned i = 0; i < n; ++i) if (a[i] != b[i]) return 0; return 1; }

__declspec(dllimport) int ssd_probe_value(void);

static int read_exact(const char *name, const char *expected) {
    char data[128];
    DWORD n = 0;
    HANDLE file = CreateFileA(name, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    BOOL ok = ReadFile(file, data, sizeof(data), &n, NULL);
    CloseHandle(file);
    return ok && n == text_length(expected) && bytes_equal(data, expected, n);
}

static void report(const char *text) {
    DWORD n;
    HANDLE output = CreateFileA("result.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (output != INVALID_HANDLE_VALUE) {
        WriteFile(output, text, (DWORD)text_length(text), &n, NULL);
        FlushFileBuffers(output);
        CloseHandle(output);
    }
}

static int test(void) {
    // Exercise relative assets from the executable's own external directory.
    // This deliberately does not claim the unmodified host's CWD conversion
    // supports E:; validate the native bridge separately.
    WCHAR path[1024];
    DWORD length = GetModuleFileNameW(NULL, path, 1024);
    if (!length || length >= 1024) return 5;
    while (length && path[length - 1] != L'\\') --length;
    if (!length) return 6;
    path[length - 1] = 0;
    if (!SetCurrentDirectoryW(path)) return 7;
    if (ssd_probe_value() != 73) { report("SSD-DLL-FAIL\n"); return 1; }
    if (!read_exact("assets\\input.txt", "SSD relative asset\n")) { report("SSD-ASSET-FAIL\n"); return 2; }
    const char *save = "SSD beside-executable save\n";
    HANDLE file = CreateFileA("beside-exe.save", GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) { report("SSD-SAVE-CREATE-FAIL\n"); return 3; }
    DWORD n = 0;
    BOOL ok = WriteFile(file, save, (DWORD)text_length(save), &n, NULL);
    BOOL flushed = FlushFileBuffers(file);
    CloseHandle(file);
    if (!ok || !flushed || n != text_length(save) || !MoveFileA("beside-exe.save", "reopened.save") ||
        !read_exact("reopened.save", save)) { report("SSD-SAVE-FAIL\n"); return 4; }
    report("SSD-EXE-DLL-ASSET-SAVE-PASS\n");
    return 0;
}

void start(void) { ExitProcess((UINT)test()); }
