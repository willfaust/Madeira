// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 David Brookes
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

/* Resolve E: only while the app has supplied a registered identity and installed
 * its mapping under a live security scope. No drive guessing or Z: fallback.
 * C: keeps the existing prefix/farm behavior, including bundled system links. */
static int madeira_storage_native(const char *prefix, const char *guest, char *out, size_t size)
{
    if (!prefix || !guest || strlen(guest) < 3 || guest[1] != ':' || guest[2] != '\\') return -1;
    int external = guest[0] == 'E' || guest[0] == 'e';
    if (!external && guest[0] != 'C' && guest[0] != 'c') return -1;
    char root[PATH_MAX], path[PATH_MAX];
    if (external) {
        const char *identity = getenv("MADEIRA_EXTERNAL_LIBRARY_ID");
        if (!identity || strlen(identity) != 36 || strspn(identity, "0123456789abcdefABCDEF-") != 36) return -1;
        if (snprintf(path, sizeof(path), "%s/dosdevices/e:", prefix) >= (int)sizeof(path)) return -1;
        struct stat st;
        if (lstat(path, &st) || !S_ISLNK(st.st_mode) || !realpath(path, root)) return -1;
        if (snprintf(path, sizeof(path), "%s/.madeira-library-id", root) >= (int)sizeof(path)) return -1;
        int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0) return -1;
        char marker[128];
        ssize_t n = read(fd, marker, sizeof(marker));
        int regular = !fstat(fd, &st) && S_ISREG(st.st_mode);
        close(fd);
        if (!regular || n != 36 || memcmp(marker, identity, 36)) return -1;
    } else if (snprintf(root, sizeof(root), "%s/drive_c", prefix) >= (int)sizeof(root)) return -1;
    if (strlen(root) >= size) return -1;
    strcpy(out, root);
    const char *part = guest + 3;
    while (*part) {
        const char *end = strchr(part, '\\');
        size_t n = end ? (size_t)(end - part) : strlen(part);
        if (!n || n > 255 || (n == 1 && part[0] == '.') ||
            (n == 2 && part[0] == '.' && part[1] == '.') || part[n - 1] == ' ' || part[n - 1] == '.') return -1;
        for (size_t i = 0; i < n; i++) if ((unsigned char)part[i] < 32 || strchr("/:\"*?<>|", part[i])) return -1;
        size_t used = strlen(out);
        if (used + n + 2 > size) return -1;
        out[used++] = '/'; memcpy(out + used, part, n); out[used + n] = 0;
        if (external) {
            struct stat st;
            if (lstat(out, &st) || S_ISLNK(st.st_mode)) return -1;
        }
        if (!end) break;
        part = end + 1;
    }
    return 0;
}
