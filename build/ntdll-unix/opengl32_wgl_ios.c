/* iOS-Madeira: dlls/opengl32/unix_wgl.c with the WoW64-window get_teb64()
 * (opengl32_teb64_ios.h). The includes before it are unix_wgl.c's own, in its
 * order, so its later #include "unix_private.h" is a no-op. */
#include "config.h"

#include <stdarg.h>
#include <stdlib.h>
#include <assert.h>

#include <pthread.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winreg.h"
#include "ntuser.h"

#include "unixlib.h"
#include "opengl32_teb64_ios.h"

#include "unix_wgl.c"
