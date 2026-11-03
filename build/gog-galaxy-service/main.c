// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// GalaxyCommunication: a do-nothing Windows service for GOG games. Some versions of
// GOG's Galaxy SDK (Galaxy.dll / Galaxy64.dll in a game) ask Windows to start the
// "GalaxyCommunication" service before they connect to GOG's client on
// 127.0.0.1:9977. Madeira answers on that port from the app (GalaxyListener); this
// service only has to exist and report that it runs, so the SDK goes on to connect.
// It does nothing else and stops when asked. Registered by the app in the prefix's
// registry (GOGGalaxy.registerService) as C:\ProgramData\GOG.com\Galaxy\redists\
// GalaxyCommunication.exe, the path GOG's own client and Heroic's comet use.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static SERVICE_STATUS_HANDLE handle;
static HANDLE stopped;
static SERVICE_STATUS status = { SERVICE_WIN32_OWN_PROCESS, SERVICE_START_PENDING, 0, NO_ERROR, 0, 0, 0 };

static DWORD WINAPI control(DWORD code, DWORD type, LPVOID data, LPVOID context) {
    (void)type; (void)data; (void)context;
    if (code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN) {
        status.dwCurrentState = SERVICE_STOP_PENDING;
        SetServiceStatus(handle, &status);
        SetEvent(stopped);
    }
    return NO_ERROR;
}

static void WINAPI service_main(DWORD argc, LPWSTR *argv) {
    (void)argc; (void)argv;
    handle = RegisterServiceCtrlHandlerExW(L"GalaxyCommunication", control, NULL);
    if (!handle) return;
    stopped = CreateEventW(NULL, TRUE, FALSE, NULL);
    status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    status.dwCurrentState = SERVICE_RUNNING;
    SetServiceStatus(handle, &status);
    WaitForSingleObject(stopped, INFINITE);
    status.dwCurrentState = SERVICE_STOPPED;
    status.dwControlsAccepted = 0;
    SetServiceStatus(handle, &status);
}

int wmain(void) {
    SERVICE_TABLE_ENTRYW table[] = { { L"GalaxyCommunication", service_main }, { NULL, NULL } };
    return StartServiceCtrlDispatcherW(table) ? 0 : 1;
}
