// Core math functions and integer type limits.
//
// Provides generic arithmetic utilities (abs, min, max, clamp, pow, gcd, lcm)
// and compile-time constants for the min/max values of all integer types.

// =============================================================================
// Unsigned Integer Limits
// =============================================================================

// Minimum value of an unsigned 8-bit integer (0).
pub const U8_MIN: u8 = 0
// Maximum value of an unsigned 8-bit integer (255).
pub const U8_MAX: u8 = 0xFF

// Minimum value of an unsigned 16-bit integer (0).
pub const U16_MIN: u16 = 0
// Maximum value of an unsigned 16-bit integer (65535).
pub const U16_MAX: u16 = 0xFFFF

// Minimum value of an unsigned 32-bit integer (0).
pub const U32_MIN: u32 = 0
// Maximum value of an unsigned 32-bit integer (4294967295).
pub const U32_MAX: u32 = 0xFFFF_FFFF

// Minimum value of an unsigned 64-bit integer (0).
pub const U64_MIN: u64 = 0
// Maximum value of an unsigned 64-bit integer (18446744073709551615).
pub const U64_MAX: u64 = 0xFFFF_FFFF_FFFF_FFFF

// =============================================================================
// Signed Integer Limits
// =============================================================================

// Minimum value of a signed 8-bit integer (-128).
pub const I8_MIN: i8 = -128
// Maximum value of a signed 8-bit integer (127).
pub const I8_MAX: i8 = 127

// Minimum value of a signed 16-bit integer (-32768).
pub const I16_MIN: i16 = -32768
// Maximum value of a signed 16-bit integer (32767).
pub const I16_MAX: i16 = 32767

// Minimum value of a signed 32-bit integer (-2147483648).
pub const I32_MIN: i32 = -2147483648
// Maximum value of a signed 32-bit integer (2147483647).
pub const I32_MAX: i32 = 2147483647

// Minimum value of a signed 64-bit integer (-9223372036854775808).
pub const I64_MIN: i64 = -9223372036854775808
// Maximum value of a signed 64-bit integer (9223372036854775807).
pub const I64_MAX: i64 = 9223372036854775807

// =============================================================================
// Basic Arithmetic
// =============================================================================

// Returns the absolute value of x.
// For signed types, returns -x when x is negative.
pub fn abs(x: $T) T {
    return if x < 0 { -x } else { x }
}

// Returns -1 if x is negative, 0 if x is zero, or 1 if x is positive.
pub fn sign(x: $T) i8 {
    return if x < 0 { -1 } else if x > 0 { 1 } else { 0 }
}

// Returns the smaller of a and b.
pub fn min(a: $T, b: T) T {
    return if a < b { a } else { b }
}

// Returns the larger of a and b.
pub fn max(a: $T, b: T) T {
    return if a < b { b } else { a }
}

// Clamps x to the inclusive range [lower, upper].
// Returns lower if x < lower, upper if x > upper, otherwise x.
pub fn clamp(x: $T, lower: T, upper: T) T {
    return max(lower, min(x, upper))
}

// =============================================================================
// Powers and Logarithms
// =============================================================================

// Returns base raised to the power of exp.
// Uses exponentiation by squaring for O(log n) multiplications.
pub fn pow(base: $T, exp: u32) T {
    let result: T = 1
    let b = base
    let e = exp
    loop {
        if e == 0 { break }
        if e % 2 == 1 {
            result = result * b
        }
        b = b * b
        e = e >> 1
    }
    return result
}

// Returns true if x is a positive power of two.
// Uses the bit trick: a power of two has exactly one bit set.
pub fn is_power_of_two(x: $T) bool {
    return x > 0 and (x & (x - 1)) == 0
}

// Returns the floor of log base 2 of x.
// x must be positive; returns 0 for x <= 1.
pub fn log2(x: $T) u32 {
    let result: u32 = 0
    let v = x
    loop {
        if v <= 1 { break }
        v = v >> 1
        result = result + 1
    }
    return result
}

// =============================================================================
// Number Theory
// =============================================================================

// Returns the greatest common divisor of a and b using the Euclidean algorithm.
// Works with signed types by taking absolute values first.
pub fn gcd(a: $T, b: T) T {
    let x = abs(a)
    let y = abs(b)
    loop {
        if y == 0 { break }
        let temp = y
        y = x % y
        x = temp
    }
    return x
}

// Returns the least common multiple of a and b.
// Returns 0 if either a or b is 0.
pub fn lcm(a: $T, b: T) T {
    if a == 0 or b == 0 {
        return 0
    }
    return abs(a) / gcd(a, b) * abs(b)
}
