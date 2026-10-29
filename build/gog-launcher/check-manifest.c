#include <assert.h>
#include "manifest.h"

int main(void) {
    unsigned char bytes[] = {2, 0, 0, 0, 'a', 0, 0, 0};
    const unsigned char *p = bytes; size_t left = sizeof(bytes);
    const uint16_t *value;
    assert(gog_string(&p, &left, &value) && value[0] == 'a' && !left);
    for (size_t n = 0; n < sizeof(bytes); n++) {
        p = bytes; left = n;
        assert(!gog_string(&p, &left, &value));
    }
    bytes[6] = 'x'; p = bytes; left = sizeof(bytes);
    assert(!gog_string(&p, &left, &value));
    bytes[0] = 255; bytes[1] = 255; p = bytes; left = sizeof(bytes);
    assert(!gog_string(&p, &left, &value));
}
