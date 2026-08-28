/* core.bits — portable scalar bit manipulation intrinsics for FLang.
 *
 * Provides leading_zeros, trailing_zeros, and count_ones for u32/u64.
 * Uses compiler builtins which map to single instructions on x86_64 and aarch64.
 */

#include <stdint.h>

#ifdef _MSC_VER
#include <intrin.h>

static uint32_t flang_clz32(uint32_t v) {
    unsigned long idx;
    return _BitScanReverse(&idx, v) ? (31u - (uint32_t)idx) : 32u;
}

static uint32_t flang_clz64(uint64_t v) {
#if defined(_M_X64) || defined(_M_ARM64)
    unsigned long idx;
    return _BitScanReverse64(&idx, v) ? (63u - (uint32_t)idx) : 64u;
#else
    uint32_t hi = (uint32_t)(v >> 32);
    return hi ? flang_clz32(hi) : 32u + flang_clz32((uint32_t)v);
#endif
}

static uint32_t flang_ctz32(uint32_t v) {
    unsigned long idx;
    return _BitScanForward(&idx, v) ? (uint32_t)idx : 32u;
}

static uint32_t flang_ctz64(uint64_t v) {
#if defined(_M_X64) || defined(_M_ARM64)
    unsigned long idx;
    return _BitScanForward64(&idx, v) ? (uint32_t)idx : 64u;
#else
    uint32_t lo = (uint32_t)v;
    return lo ? flang_ctz32(lo) : 32u + flang_ctz32((uint32_t)(v >> 32));
#endif
}

uint32_t leading_zeros_u32(uint32_t v) { return v ? flang_clz32(v) : 32u; }
uint64_t leading_zeros_u64(uint64_t v) { return v ? (uint64_t)flang_clz64(v) : 64u; }
uint32_t trailing_zeros_u32(uint32_t v) { return v ? flang_ctz32(v) : 32u; }
uint64_t trailing_zeros_u64(uint64_t v) { return v ? (uint64_t)flang_ctz64(v) : 64u; }

uint32_t count_ones_u32(uint32_t v) { return (uint32_t)__popcnt(v); }
uint64_t count_ones_u64(uint64_t v) {
#if defined(_M_X64) || defined(_M_ARM64)
    return (uint64_t)__popcnt64(v);
#else
    return (uint64_t)(__popcnt((uint32_t)v) + __popcnt((uint32_t)(v >> 32)));
#endif
}

#else

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

#endif
