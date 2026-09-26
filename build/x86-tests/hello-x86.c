/* Smoke test PE for the WoW64 (i386) path (docs/WOW64.md): a minimal real
 * 32-bit PE, i686 mingw, importing only kernel32 (GetStdHandle, WriteFile,
 * ExitProcess). Its string reaches the app log through Wine and the iOS
 * runtime, and exit code 42 is reported.
 *
 * No CRT: this file supplies its own PE entry point (`start`, which the
 * i386 Windows C ABI mangles to the symbol `_start`) and is linked with
 * -nostdlib, so the ONLY DLL this exe imports is kernel32.dll -- verified
 * with `i686-w64-mingw32-objdump -p hello-x86.exe` (see build.sh).
 */
#include <windows.h>

void start(void)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    static const char msg[] = "MADEIRA-X86-32: hello from a 32-bit PE\n";

    WriteFile(h, msg, sizeof(msg) - 1, &written, NULL);
    ExitProcess(42);
}
