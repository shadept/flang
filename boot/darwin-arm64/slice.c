/* core.slice - memswap: exchange the bytes of two non-overlapping regions.
 *
 * The primitive `swap` is built on: no value is read into a second location, so it holds for an
 * element type that owns something, where a three-assignment swap would be two owners of one
 * resource.
 */

#include <stddef.h>
#include <string.h>

void memswap(unsigned char *a, unsigned char *b, size_t len) {
    unsigned char buf[64];
    while (len > 0) {
        size_t n = len < sizeof buf ? len : sizeof buf;
        memcpy(buf, a, n);
        memcpy(a, b, n);
        memcpy(b, buf, n);
        a += n;
        b += n;
        len -= n;
    }
}
