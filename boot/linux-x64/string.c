/* core.string companion — libc shims for String construction helpers. */

#include <string.h>
#include <stddef.h>

size_t __flang_strlen(const unsigned char* ptr) {
    return strlen((const char*)ptr);
}
