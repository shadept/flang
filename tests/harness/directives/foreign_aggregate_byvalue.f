//! TEST: foreign_aggregate_byvalue
//! STDOUT: PASS

// A `#foreign` function may take and return an aggregate BY VALUE.
// `std.simd`'s intrinsics are the real case: `v128_load(&u8) Vec128` and
// `v128_cmpeq_u8(Vec128, Vec128) Vec128` are C functions in stdlib/std/simd.c.
//
// Regression: FIR had no aggregate type, so these signatures could not be
// declared, `ty_lowerable` refused to register them, and every call reported
// "callee is not a callable value". They now cross as `IrType.Agg` - a C
// struct of the FLang layout's size and alignment, which the platform ABI
// classifies exactly as the companion C definition does.

import core.io
import std.simd

pub fn main() i32 {
    let byte: u8 = 0xAB
    const src = v128_splat_u8(byte)

    // Round-trip through memory: proves the struct carried real bytes
    // across the C boundary, not a pointer or a truncated value.
    let buf: [u8; 16] = [0; 16]
    v128_store(&buf[0], src)
    if buf[0] != 0xAB or buf[15] != 0xAB {
        println("FAIL: store did not write all lanes")
        return 1
    }

    // Load it back and compare by value - both argument and return are
    // aggregates here.
    const loaded = v128_load(&buf[0])
    if v128_movemask(v128_cmpeq_u8(loaded, src)) != 65535u32 {
        println("FAIL: round-tripped vector did not compare equal")
        return 1
    }

    let low: u8 = 0x0F
    const a = v128_splat_u8(low)
    if v128_count_true(v128_cmpeq_u8(a, a)) != 16u32 {
        println("FAIL: self-comparison should set all 16 lanes")
        return 1
    }
    if v128_movemask(v128_cmpeq_u8(a, v128_not(a))) != 0u32 {
        println("FAIL: a vector must not equal its complement")
        return 1
    }

    println("PASS")
    return 0
}
