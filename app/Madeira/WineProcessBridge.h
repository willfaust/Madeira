#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Start Wine process initialization on a background thread.
// Must be called AFTER wineserver is running.
// prefix_path: path to the Wine prefix directory
// Returns 0 on success, -1 on error.
int wine_process_start(const char *prefix_path);

/* Guest stdin. -1 until the pipe is enabled via Documents/madeira-stdin.txt. */
extern int madeira_stdin_master;
int  madeira_stdin_is_open(void);
long madeira_stdin_write(const void *buf, unsigned long len);
void madeira_stdin_close(void);

// Check if Wine process is running
int wine_process_is_running(void);

// Steam S0 net-test VPN gate: write C:\madeira-continue.flag into the
// prefix's drive_c so the paused winhttp-test.exe resumes to the Steam
// stage. Called by the "Continue Net Test" UI button after the user has
// detached the JIT debugger and switched VPNs. Returns 0 on success.
int madeira_write_continue_flag(void);

#ifdef __cplusplus
}
#endif
