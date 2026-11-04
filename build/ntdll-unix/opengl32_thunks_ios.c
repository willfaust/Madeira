/* iOS-Madeira: dlls/opengl32/unix_thunks.c with the WoW64-window get_teb64()
 * (opengl32_teb64_ios.h). The includes before it are unix_thunks.c's own, in
 * its order, so its later #include "unix_private.h" is a no-op. */
#include <stdarg.h>
#include <stddef.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "wingdi.h"

#include "unixlib.h"
#include "opengl32_teb64_ios.h"

#include "unix_thunks.c"
