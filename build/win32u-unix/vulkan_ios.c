/* Keep Wine's Vulkan implementation unchanged, resolving a signed framework
 * relative to the actual app executable if dyld does not expand its token.
 * SPDX-License-Identifier: GPL-3.0-or-later
 * With the additional permission in LICENSE-EXCEPTION.md.
 */
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void *madeira_vulkan_dlopen( const char *path, int flags )
{
    static const char prefix[] = "@executable_path/";
    void *handle = dlopen( path, flags );
    char executable[PATH_MAX], absolute[PATH_MAX], *slash;
    uint32_t size = sizeof(executable);
    int length;

    if (handle || strncmp( path, prefix, sizeof(prefix) - 1 )) return handle;
    if (_NSGetExecutablePath( executable, &size ) || !(slash = strrchr( executable, '/' )))
        return NULL;
    *slash = 0;
    length = snprintf( absolute, sizeof(absolute), "%s/%s", executable, path + sizeof(prefix) - 1 );
    if (length < 0 || (size_t)length >= sizeof(absolute)) return NULL;
    return dlopen( absolute, flags );
}

#define dlopen madeira_vulkan_dlopen
#include "../../wine/dlls/win32u/vulkan.c"
#undef dlopen
