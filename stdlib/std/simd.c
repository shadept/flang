/* std.simd — portable 128-bit SIMD runtime for FLang.
 *
 * Provides inline implementations of Vec128 operations using:
 *   - SSE2 intrinsics on x86_64
 *   - NEON intrinsics on aarch64
 *   - Scalar fallback otherwise
 *
 * This file is compiled alongside the generated C code by the FLang compiler.
 */

#include <stdint.h>
#include <string.h>

#ifdef _MSC_VER
#define FLANG_ALIGN_PRE(n) __declspec(align(n))
#define FLANG_ALIGN_POST(n)
#else
#define FLANG_ALIGN_PRE(n)
#define FLANG_ALIGN_POST(n) __attribute__((aligned(n)))
#endif

/* Struct definition matches what the FLang codegen emits */
FLANG_ALIGN_PRE(16) struct FLANG_ALIGN_POST(16) std_simd_Vec128 { uint8_t _data[16]; };
typedef struct std_simd_Vec128 std_simd_Vec128;

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>

std_simd_Vec128 v128_load(const void* p) {
    std_simd_Vec128 v;
    _mm_storeu_si128((__m128i*)&v, _mm_loadu_si128((const __m128i*)p));
    return v;
}

std_simd_Vec128 v128_splat_u8(uint8_t val) {
    std_simd_Vec128 v;
    _mm_storeu_si128((__m128i*)&v, _mm_set1_epi8((char)val));
    return v;
}

std_simd_Vec128 v128_cmpeq_u8(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    _mm_storeu_si128((__m128i*)&r,
        _mm_cmpeq_epi8(_mm_loadu_si128((const __m128i*)&a),
                        _mm_loadu_si128((const __m128i*)&b)));
    return r;
}

std_simd_Vec128 v128_or(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    _mm_storeu_si128((__m128i*)&r,
        _mm_or_si128(_mm_loadu_si128((const __m128i*)&a),
                     _mm_loadu_si128((const __m128i*)&b)));
    return r;
}

std_simd_Vec128 v128_and(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    _mm_storeu_si128((__m128i*)&r,
        _mm_and_si128(_mm_loadu_si128((const __m128i*)&a),
                      _mm_loadu_si128((const __m128i*)&b)));
    return r;
}

std_simd_Vec128 v128_andnot(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    _mm_storeu_si128((__m128i*)&r,
        _mm_andnot_si128(_mm_loadu_si128((const __m128i*)&a),
                         _mm_loadu_si128((const __m128i*)&b)));
    return r;
}

uint32_t v128_count_true(std_simd_Vec128 a) {
    return (uint32_t)__builtin_popcount(
        (unsigned)_mm_movemask_epi8(_mm_loadu_si128((const __m128i*)&a)));
}

uint32_t v128_movemask(std_simd_Vec128 a) {
    return (uint32_t)_mm_movemask_epi8(_mm_loadu_si128((const __m128i*)&a));
}

std_simd_Vec128 v128_zero(void) {
    std_simd_Vec128 v;
    _mm_storeu_si128((__m128i*)&v, _mm_setzero_si128());
    return v;
}

void v128_store(void* p, std_simd_Vec128 a) {
    _mm_storeu_si128((__m128i*)p, _mm_loadu_si128((const __m128i*)&a));
}

std_simd_Vec128 v128_not(std_simd_Vec128 a) {
    std_simd_Vec128 r;
    __m128i ones = _mm_set1_epi8((char)0xFF);
    _mm_storeu_si128((__m128i*)&r,
        _mm_xor_si128(_mm_loadu_si128((const __m128i*)&a), ones));
    return r;
}

std_simd_Vec128 v128_shuffle(std_simd_Vec128 a, std_simd_Vec128 idx) {
    std_simd_Vec128 r;
    _mm_storeu_si128((__m128i*)&r,
        _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)&a),
                         _mm_loadu_si128((const __m128i*)&idx)));
    return r;
}

std_simd_Vec128 v128_shr_u8(std_simd_Vec128 a, uint8_t imm) {
    std_simd_Vec128 r;
    /* SSE2 has no per-byte shift; shift 16-bit lanes then mask off crossed bits */
    __m128i v = _mm_loadu_si128((const __m128i*)&a);
    __m128i shifted = _mm_srli_epi16(v, imm);
    __m128i mask = _mm_set1_epi8((char)(0xFF >> imm));
    _mm_storeu_si128((__m128i*)&r, _mm_and_si128(shifted, mask));
    return r;
}

std_simd_Vec128 v128_clmul(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    _mm_storeu_si128((__m128i*)&r,
        _mm_clmulepi64_si128(_mm_loadu_si128((const __m128i*)&a),
                             _mm_loadu_si128((const __m128i*)&b), 0x00));
    return r;
}

#elif defined(__aarch64__) || defined(_M_ARM64)
#include <arm_neon.h>

std_simd_Vec128 v128_load(const void* p) {
    std_simd_Vec128 v;
    vst1q_u8(v._data, vld1q_u8((const uint8_t*)p));
    return v;
}

std_simd_Vec128 v128_splat_u8(uint8_t val) {
    std_simd_Vec128 v;
    vst1q_u8(v._data, vdupq_n_u8(val));
    return v;
}

std_simd_Vec128 v128_cmpeq_u8(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    vst1q_u8(r._data, vceqq_u8(vld1q_u8(a._data), vld1q_u8(b._data)));
    return r;
}

std_simd_Vec128 v128_or(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    vst1q_u8(r._data, vorrq_u8(vld1q_u8(a._data), vld1q_u8(b._data)));
    return r;
}

std_simd_Vec128 v128_and(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    vst1q_u8(r._data, vandq_u8(vld1q_u8(a._data), vld1q_u8(b._data)));
    return r;
}

std_simd_Vec128 v128_andnot(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    vst1q_u8(r._data, vbicq_u8(vld1q_u8(b._data), vld1q_u8(a._data)));
    return r;
}

uint32_t v128_count_true(std_simd_Vec128 a) {
    uint8x16_t v = vld1q_u8(a._data);
    uint8x16_t ones = vshrq_n_u8(v, 7);
    return (uint32_t)vaddvq_u8(ones);
}

uint32_t v128_movemask(std_simd_Vec128 a) {
    static const uint8_t shift[] = {0,1,2,3,4,5,6,7,0,1,2,3,4,5,6,7};
    uint8x16_t v = vshrq_n_u8(vld1q_u8(a._data), 7);
    uint8x16_t shifted = vshlq_u8(v, vreinterpretq_s8_u8(vld1q_u8(shift)));
    uint8x8_t lo = vget_low_u8(shifted);
    uint8x8_t hi = vget_high_u8(shifted);
    return (uint32_t)(vaddv_u8(lo) | (vaddv_u8(hi) << 8));
}

std_simd_Vec128 v128_zero(void) {
    std_simd_Vec128 v;
    vst1q_u8(v._data, vdupq_n_u8(0));
    return v;
}

void v128_store(void* p, std_simd_Vec128 a) {
    vst1q_u8((uint8_t*)p, vld1q_u8(a._data));
}

std_simd_Vec128 v128_not(std_simd_Vec128 a) {
    std_simd_Vec128 r;
    vst1q_u8(r._data, vmvnq_u8(vld1q_u8(a._data)));
    return r;
}

std_simd_Vec128 v128_shuffle(std_simd_Vec128 a, std_simd_Vec128 idx) {
    std_simd_Vec128 r;
    vst1q_u8(r._data, vqtbl1q_u8(vld1q_u8(a._data), vld1q_u8(idx._data)));
    return r;
}

std_simd_Vec128 v128_shr_u8(std_simd_Vec128 a, uint8_t imm) {
    std_simd_Vec128 r;
    /* NEON vshrq_n_u8 requires a compile-time constant; use a shift-by-variable path */
    uint8x16_t v = vld1q_u8(a._data);
    int8x16_t neg_imm = vdupq_n_s8(-(int8_t)imm);
    vst1q_u8(r._data, vshlq_u8(v, neg_imm));
    return r;
}

std_simd_Vec128 v128_clmul(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    poly64_t pa = (poly64_t)vget_low_u64(vreinterpretq_u64_u8(vld1q_u8(a._data)));
    poly64_t pb = (poly64_t)vget_low_u64(vreinterpretq_u64_u8(vld1q_u8(b._data)));
    poly128_t product = vmull_p64(pa, pb);
    vst1q_u8(r._data, vreinterpretq_u8_p128(product));
    return r;
}

#else
/* Scalar fallback */

std_simd_Vec128 v128_load(const void* p) {
    std_simd_Vec128 v; memcpy(v._data, p, 16); return v;
}

std_simd_Vec128 v128_splat_u8(uint8_t val) {
    std_simd_Vec128 v; memset(v._data, val, 16); return v;
}

std_simd_Vec128 v128_cmpeq_u8(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    for (int i = 0; i < 16; i++) r._data[i] = a._data[i] == b._data[i] ? 0xFF : 0;
    return r;
}

std_simd_Vec128 v128_or(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    for (int i = 0; i < 16; i++) r._data[i] = a._data[i] | b._data[i];
    return r;
}

std_simd_Vec128 v128_and(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    for (int i = 0; i < 16; i++) r._data[i] = a._data[i] & b._data[i];
    return r;
}

std_simd_Vec128 v128_andnot(std_simd_Vec128 a, std_simd_Vec128 b) {
    std_simd_Vec128 r;
    for (int i = 0; i < 16; i++) r._data[i] = ~a._data[i] & b._data[i];
    return r;
}

uint32_t v128_count_true(std_simd_Vec128 a) {
    uint32_t c = 0;
    for (int i = 0; i < 16; i++) if (a._data[i]) c++;
    return c;
}

uint32_t v128_movemask(std_simd_Vec128 a) {
    uint32_t m = 0;
    for (int i = 0; i < 16; i++) m |= ((a._data[i] >> 7) & 1) << i;
    return m;
}

std_simd_Vec128 v128_zero(void) {
    std_simd_Vec128 v; memset(v._data, 0, 16); return v;
}

void v128_store(void* p, std_simd_Vec128 a) {
    memcpy(p, a._data, 16);
}

std_simd_Vec128 v128_not(std_simd_Vec128 a) {
    std_simd_Vec128 r;
    for (int i = 0; i < 16; i++) r._data[i] = ~a._data[i];
    return r;
}

std_simd_Vec128 v128_shuffle(std_simd_Vec128 a, std_simd_Vec128 idx) {
    std_simd_Vec128 r;
    for (int i = 0; i < 16; i++)
        r._data[i] = (idx._data[i] & 0x80) ? 0 : a._data[idx._data[i] & 0x0F];
    return r;
}

std_simd_Vec128 v128_shr_u8(std_simd_Vec128 a, uint8_t imm) {
    std_simd_Vec128 r;
    for (int i = 0; i < 16; i++) r._data[i] = a._data[i] >> imm;
    return r;
}

std_simd_Vec128 v128_clmul(std_simd_Vec128 a, std_simd_Vec128 b) {
    /* Scalar carryless multiply of low 64 bits */
    uint64_t x, y;
    memcpy(&x, a._data, 8);
    memcpy(&y, b._data, 8);
    uint64_t lo = 0, hi = 0;
    for (int i = 0; i < 64; i++) {
        if ((y >> i) & 1) {
            lo ^= x << i;
            if (i > 0) hi ^= x >> (64 - i);
        }
    }
    std_simd_Vec128 r;
    memset(r._data, 0, 16);
    memcpy(r._data, &lo, 8);
    memcpy(r._data + 8, &hi, 8);
    return r;
}

#endif

/* Platform-agnostic constructors */

std_simd_Vec128 v128_from_u64x2(uint64_t lo, uint64_t hi) {
    std_simd_Vec128 v;
    memcpy(v._data, &lo, 8);
    memcpy(v._data + 8, &hi, 8);
    return v;
}

std_simd_Vec128 v128_from_u32x4(uint32_t a, uint32_t b, uint32_t c, uint32_t d) {
    std_simd_Vec128 v;
    memcpy(v._data, &a, 4);
    memcpy(v._data + 4, &b, 4);
    memcpy(v._data + 8, &c, 4);
    memcpy(v._data + 12, &d, 4);
    return v;
}

std_simd_Vec128 v128_from_u64(uint64_t val) {
    std_simd_Vec128 v;
    memset(v._data, 0, 16);
    memcpy(v._data, &val, 8);
    return v;
}
