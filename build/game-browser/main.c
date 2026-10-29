// SPDX-License-Identifier: GPL-3.0-or-later
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <shellapi.h>
#include <stdlib.h>
#include <wchar.h>

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, LPWSTR command, int show) {
    (void)instance; (void)previous; (void)command; (void)show;
    int argc; LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 1;
    LPCWSTR url = NULL;
    for (int i = 1; i < argc; i++) {
        if (!_wcsnicmp(argv[i], L"http://", 7) || !_wcsnicmp(argv[i], L"https://", 8)) { url = argv[i]; break; }
    }
    WCHAR address[128];
    DWORD size = GetEnvironmentVariableW(L"MADEIRA_BROWSER_ADDRESS", address, 128);
    if (!url || !size || size >= 128) { LocalFree(argv); return 1; }
    WCHAR *path; unsigned long port = wcstoul(address, &path, 10);
    if (!port || port > 65535 || *path != L'/') { LocalFree(argv); return 1; }
    int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, url, -1, NULL, 0, NULL, NULL);
    if (count < 2 || count > 2048) { LocalFree(argv); return 1; }
    char bytes[2048];
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, url, -1, bytes, count, NULL, NULL)) { LocalFree(argv); return 1; }
    HINTERNET session = WinHttpOpen(L"Madeira game browser", WINHTTP_ACCESS_TYPE_NO_PROXY, NULL, NULL, 0);
    if (!session) { LocalFree(argv); return 1; }
    WinHttpSetTimeouts(session, 2000, 2000, 2000, 2000);
    HINTERNET connection = WinHttpConnect(session, L"127.0.0.1", (INTERNET_PORT)port, 0);
    HINTERNET request = connection ? WinHttpOpenRequest(connection, L"POST", path, NULL, NULL, NULL, 0) : NULL;
    DWORD status = 0, statusSize = sizeof(status);
    BOOL ok = request && WinHttpSendRequest(request, L"Content-Type: text/plain\r\n", (DWORD)-1,
        bytes, count - 1, count - 1, 0) && WinHttpReceiveResponse(request, NULL) &&
        WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &statusSize, NULL);
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session); LocalFree(argv);
    return ok && status == 202 ? 0 : 1;
}
