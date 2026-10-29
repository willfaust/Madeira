#include <stdint.h>
#include <stddef.h>
#include <string.h>

static int gog_number(const unsigned char **p, size_t *left, uint32_t *out) {
    if (*left < 4) return 0;
    *out = (uint32_t)(*p)[0] | (uint32_t)(*p)[1] << 8 | (uint32_t)(*p)[2] << 16 | (uint32_t)(*p)[3] << 24;
    *p += 4; *left -= 4;
    return 1;
}

static int gog_string(const unsigned char **p, size_t *left, const uint16_t **out) {
    uint32_t count;
    if (!gog_number(p, left, &count) || !count || count > 32767 || count * 2 > *left) return 0;
    const uint16_t *s = (const uint16_t *)*p;
    if (s[count - 1]) return 0;
    for (uint32_t i = 0; i + 1 < count; i++) if (!s[i]) return 0;
    *out = s; *p += count * 2; *left -= count * 2;
    return 1;
}
