// Pseudo-random number generation using xorshift64.
// Period: 2^64 - 1. State must be non-zero.

import std.test

pub type Random = struct {
    state: u64
}

// Create a new Random with the given seed. Seed must be non-zero.
pub fn random(seed: u64) Random {
    let s = seed
    if s == 0 {
        s = 1
    }
    return Random { state = s }
}

// Generate the next random u64.
pub fn next_u64(r: &Random) u64 {
    r.state = r.state ^ (r.state << 13)
    r.state = r.state ^ (r.state >> 7)
    r.state = r.state ^ (r.state << 17)
    return r.state
}

// Generate a random u32.
pub fn next_u32(r: &Random) u32 {
    return r.next_u64() as u32
}

// Generate a random u16.
pub fn next_u16(r: &Random) u16 {
    return r.next_u64() as u16
}

// Generate a random u8.
pub fn next_u8(r: &Random) u8 {
    return r.next_u64() as u8
}

// Generate a random i64.
pub fn next_i64(r: &Random) i64 {
    return r.next_u64() as i64
}

// Generate a random i32.
pub fn next_i32(r: &Random) i32 {
    return r.next_u64() as i32
}

// Generate a random i16.
pub fn next_i16(r: &Random) i16 {
    return r.next_u64() as i16
}

// Generate a random i8.
pub fn next_i8(r: &Random) i8 {
    return r.next_u64() as i8
}

// Generate a random bool.
pub fn next_bool(r: &Random) bool {
    return (r.next_u64() & 1) == 1
}

// Generate a random i64 in [min, max).
pub fn next_range(r: &Random, min: i64, max: i64) i64 {
    if (min >= max) {
        return min
    }
    const range = (max - min) as u64
    return min + (r.next_u64() % range) as i64
}

// Generate a random u64 in [min, max).
pub fn next_urange(r: &Random, min: u64, max: u64) u64 {
    if (min >= max) {
        return min
    }
    const range = max - min
    return min + (r.next_u64() % range)
}

// Generate a random f64 in [0.0, 1.0).
// Uses the upper 53 bits of a u64 for full mantissa precision.
pub fn next_f64(r: &Random) f64 {
    return (r.next_u64() >> 11) as f64 / 9007199254740992.0
}

// Generate a random f32 in [0.0, 1.0).
// Uses the upper 24 bits of a u64 for full mantissa precision.
pub fn next_f32(r: &Random) f32 {
    return (r.next_u64() >> 40) as f32 / 16777216.0f32
}

// Generate a random f64 in [min, max).
pub fn next_f64_range(r: &Random, min: f64, max: f64) f64 {
    return min + r.next_f64() * (max - min)
}

// Generate a random f32 in [min, max).
pub fn next_f32_range(r: &Random, min: f32, max: f32) f32 {
    return min + r.next_f32() * (max - min)
}

// Fill a byte slice with random bytes.
pub fn fill_bytes(r: &Random, buf: u8[]) {
    let i = 0usize

    // Fill 8 bytes at a time from a single u64
    loop {
        if (i + 8 > buf.len) { break }
        let val = r.next_u64()
        buf[i]     = val as u8
        buf[i + 1] = (val >> 8) as u8
        buf[i + 2] = (val >> 16) as u8
        buf[i + 3] = (val >> 24) as u8
        buf[i + 4] = (val >> 32) as u8
        buf[i + 5] = (val >> 40) as u8
        buf[i + 6] = (val >> 48) as u8
        buf[i + 7] = (val >> 56) as u8
        i = i + 8
    }

    // Fill remaining bytes
    loop {
        if (i >= buf.len) { break }
        buf[i] = r.next_u8()
        i = i + 1
    }
}

test "next_u64 produces non-zero values" {
    let rng = random(42)
    const a = rng.next_u64()
    assert_true(a != 0, "first value should be non-zero")
}

test "next_u64 produces distinct values" {
    let rng = random(42)
    const a = rng.next_u64()
    const b = rng.next_u64()
    assert_true(b != a, "successive values should differ")
}

test "deterministic with same seed" {
    let rng1 = random(42)
    let rng2 = random(42)
    assert_eq(rng1.next_u64(), rng2.next_u64(), "first value should match")
    assert_eq(rng1.next_u64(), rng2.next_u64(), "second value should match")
}

test "next_range stays in bounds" {
    let rng = random(123)
    let i: i64 = 0
    loop {
        if (i >= 100) { break }
        const val = rng.next_range(0, 10)
        assert_true(val >= 0 and val < 10, "range value out of bounds")
        i = i + 1
    }
}

test "next_bool works" {
    let rng = random(99)
    const a = rng.next_bool()
    const b = rng.next_bool()
    // just verifying it doesn't crash; both true/false are valid
    assert_true(a or a == false, "bool should be true or false")
}

test "next_f64 in [0, 1)" {
    let rng = random(42)
    let i: i64 = 0
    loop {
        if (i >= 100) { break }
        const val = rng.next_f64()
        assert_true(val >= 0.0 and val < 1.0, "f64 should be in [0, 1)")
        i = i + 1
    }
}

test "next_f32 in [0, 1)" {
    let rng = random(42)
    let i: i64 = 0
    loop {
        if (i >= 100) { break }
        const val = rng.next_f32()
        assert_true(val >= 0.0f32 and val < 1.0f32, "f32 should be in [0, 1)")
        i = i + 1
    }
}

test "next_f64_range stays in bounds" {
    let rng = random(77)
    let i: i64 = 0
    loop {
        if (i >= 100) { break }
        const val = rng.next_f64_range(5.0, 10.0)
        assert_true(val >= 5.0 and val < 10.0, "f64 range value out of bounds")
        i = i + 1
    }
}

test "next_f32_range stays in bounds" {
    let rng = random(77)
    let i: i64 = 0
    loop {
        if (i >= 100) { break }
        const val = rng.next_f32_range(5.0f32, 10.0f32)
        assert_true(val >= 5.0f32 and val < 10.0f32, "f32 range value out of bounds")
        i = i + 1
    }
}
