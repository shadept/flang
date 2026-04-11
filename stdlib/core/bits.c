/* core.bits — portable scalar bit manipulation intrinsics for FLang.
 *
 * Provides leading_zeros, trailing_zeros, and count_ones for u32/u64.
 * Uses compiler builtins which map to single instructions on x86_64 and aarch64.
 */

#include <stdint.h>

uint32_t leading_zeros_u32(uint32_t v) {
    return v ? (uint32_t)__builtin_clz(v) : 32;
}

uint64_t leading_zeros_u64(uint64_t v) {
    return v ? (uint64_t)__builtin_clzll(v) : 64;
}

uint32_t trailing_zeros_u32(uint32_t v) {
    return v ? (uint32_t)__builtin_ctz(v) : 32;
}

uint64_t trailing_zeros_u64(uint64_t v) {
    return v ? (uint64_t)__builtin_ctzll(v) : 64;
}

uint32_t count_ones_u32(uint32_t v) {
    return (uint32_t)__builtin_popcount(v);
}

uint64_t count_ones_u64(uint64_t v) {
    return (uint64_t)__builtin_popcountll(v);
}
