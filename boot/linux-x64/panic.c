/* core.panic companion: the message line, unbuffered, straight to the OS. Nothing else in core
 * writes, so this is the whole of core's output path; termination stays in panic.f, where the
 * test-runner hand-off is a compile-time choice. */

#include <stddef.h>
#include <stdint.h>
#ifdef _WIN32
#include <io.h>
#define flang_write(fd, p, n) _write((fd), (p), (unsigned int)(n))
#else
#include <unistd.h>
#define flang_write(fd, p, n) write((fd), (p), (n))
#endif

static void write_all(int fd, const uint8_t* buf, size_t len) {
    while (len > 0) {
        long n = (long)flang_write(fd, buf, len > (1u << 30) ? (1u << 30) : len);
        if (n <= 0) return;
        buf += n;
        len -= (size_t)n;
    }
}

void __flang_panic(const uint8_t* msg, size_t len) {
    write_all(1, msg, len);
    write_all(1, (const uint8_t*)"\n", 1);
}
