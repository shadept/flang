#include <stdatomic.h>
#include <stddef.h>

size_t __flang_atomic_load(size_t* ptr) {
    return atomic_load((_Atomic size_t*)ptr);
}

size_t __flang_atomic_add(size_t* ptr, size_t val) {
    return atomic_fetch_add((_Atomic size_t*)ptr, val);
}

size_t __flang_atomic_sub(size_t* ptr, size_t val) {
    return atomic_fetch_sub((_Atomic size_t*)ptr, val);
}
