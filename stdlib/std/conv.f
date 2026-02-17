// Zero-allocation conversion functions.
// Buffer-based formatting and parsing for integers and booleans.

import std.test
import std.result

// =============================================================================
// Types
// =============================================================================

pub type ConvError = enum {
    InvalidBase
    BufferTooSmall
    Overflow
    InvalidInput
}

// =============================================================================
// Constants
// =============================================================================

const I64_MIN_ABS: u64 = 0x8000_0000_0000_0000

// =============================================================================
// Integer → Buffer
// =============================================================================

// Format an unsigned 64-bit integer into buf. Returns bytes written.
// Supports bases 2–16. Lowercase a–f for hex.
pub fn format_u64(val: u64, buf: u8[], base: u8 = 10) Result(usize, ConvError) {
    if base < 2 or base > 16 {
        return Err(ConvError.InvalidBase)
    }

    if val == 0 {
        if buf.len < 1 {
            return Err(ConvError.BufferTooSmall)
        }
        buf[0] = b'0'
        return Ok(1usize)
    }

    // Extract digits right-to-left into temp buffer
    let tmp = [0u8; 64]
    let pos = tmp.len
    const base_u64 = base as u64

    loop {
        if val == 0 { break }
        const digit = (val % base_u64) as u8
        val = val / base_u64
        pos = pos - 1
        if digit < 10 {
            tmp[pos] = b'0' + digit
        } else {
            tmp[pos] = b'a' - 10 + digit
        }
    }

    const len = 64 - pos
    if buf.len < len {
        return Err(ConvError.BufferTooSmall)
    }

    // Copy to front of caller buffer
    let i = 0
    loop {
        if i >= len { break }
        buf[i] = tmp[pos + i]
        i = i + 1
    }

    return Ok(len)
}

// Format a signed 64-bit integer into buf. Returns bytes written.
// Supports bases 2–16. Lowercase a–f for hex.
pub fn format_i64(val: i64, buf: u8[], base: u8 = 10) Result(usize, ConvError) {
    if base < 2 or base > 16 {
        return Err(ConvError.InvalidBase)
    }

    const is_negative = val < 0
    let abs_val: u64 = if is_negative { (0 - val) as u64 } else { val as u64 }

    let offset = 0usize
    if is_negative {
        if buf.len < 2 {
            return Err(ConvError.BufferTooSmall)
        }
        buf[0] = b'-'
        offset = 1
    }

    const result = format_u64(abs_val, buf[offset..], base)
    return result match {
        Ok(written) => Ok(offset + written),
        Err(e) => Err(e)
    }
}

// =============================================================================
// Buffer → Integer
// =============================================================================

// Parse an unsigned 64-bit integer from a byte buffer.
// Returns (value, bytes_consumed).
pub fn parse_u64(s: u8[], base: u8 = 10) Result((u64, usize), ConvError) {
    if base < 2 or base > 16 {
        return Err(ConvError.InvalidBase)
    }
    if s.len == 0 {
        return Err(ConvError.InvalidInput)
    }

    const base_u64 = base as u64
    const max_before_mul = U64_MAX / base_u64
    let value: u64 = 0
    let consumed = 0

    loop {
        if consumed >= s.len { break }
        const c = s[consumed]

        let digit_val: u64 = 0
        let valid = false

        if c >= b'0' and c <= b'9' {
            digit_val = (c - b'0') as u64
            valid = digit_val < base_u64
        } else if c >= b'a' and c <= b'f' {
            digit_val = (c - b'a' + 10) as u64
            valid = digit_val < base_u64
        } else if c >= b'A' and c <= b'F' {
            digit_val = (c - b'A' + 10) as u64
            valid = digit_val < base_u64
        }

        if valid == false { break }

        // Overflow check: value * base + digit > U64_MAX
        if value > max_before_mul {
            return Err(ConvError.Overflow)
        }
        value = value * base_u64
        if digit_val > U64_MAX - value {
            return Err(ConvError.Overflow)
        }
        value = value + digit_val
        consumed = consumed + 1
    }

    if consumed == 0 {
        return Err(ConvError.InvalidInput)
    }

    return Ok((value, consumed))
}

// Parse a signed 64-bit integer from a byte buffer.
// Returns (value, bytes_consumed).
pub fn parse_i64(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    if base < 2 or base > 16 {
        return Err(ConvError.InvalidBase)
    }
    if s.len == 0 {
        return Err(ConvError.InvalidInput)
    }

    let negative = false
    let offset = 0usize

    if s[0] == b'-' {
        negative = true
        offset = 1
        if offset >= s.len {
            return Err(ConvError.InvalidInput)
        }
    }

    const result = parse_u64(s[offset..], base)
    if result.is_err() {
        const e: ConvError = result.unwrap_err()
        return Err(e)
    }
    const p = result.unwrap()
    const val = p.0
    const digits = p.1

    if negative {
        if val > I64_MIN_ABS {
            return Err(ConvError.Overflow)
        }
        if val == I64_MIN_ABS {
            const min_val: i64 = 0 - I64_MAX as i64 - 1
            return Ok((min_val, offset + digits))
        }
        const neg_val: i64 = 0 - val as i64
        return Ok((neg_val, offset + digits))
    }

    if val > I64_MAX as usize {
        return Err(ConvError.Overflow)
    }
    const pos_val: i64 = val as i64
    return Ok((pos_val, offset + digits))
}

// =============================================================================
// Convenience Parsers
// =============================================================================

// Parse a u8. Returns (value, bytes_consumed) with value guaranteed <= 0xFF.
pub fn parse_u8(s: u8[], base: u8 = 10) Result((u64, usize), ConvError) {
    return parse_u64(s, base) match {
        Ok(p) => if p.0 > 0xFF { Err(ConvError.Overflow) } else { Ok(p) },
        Err(e) => Err(e)
    }
}

// Parse a u16. Returns (value, bytes_consumed) with value guaranteed <= 0xFFFF.
pub fn parse_u16(s: u8[], base: u8 = 10) Result((u64, usize), ConvError) {
    return parse_u64(s, base) match {
        Ok(p) => if p.0 > 0xFFFF { Err(ConvError.Overflow) } else { Ok(p) },
        Err(e) => Err(e)
    }
}

// Parse a u32. Returns (value, bytes_consumed) with value guaranteed <= 0xFFFF_FFFF.
pub fn parse_u32(s: u8[], base: u8 = 10) Result((u64, usize), ConvError) {
    return parse_u64(s, base) match {
        Ok(p) => if p.0 > 0xFFFF_FFFF { Err(ConvError.Overflow) } else { Ok(p) },
        Err(e) => Err(e)
    }
}

// Parse a usize. Returns (value, bytes_consumed).
pub fn parse_usize(s: u8[], base: u8 = 10) Result((u64, usize), ConvError) {
    return parse_u64(s, base)
}

// Parse an i8. Returns (value, bytes_consumed) with value guaranteed in [-128, 127].
pub fn parse_i8(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    return parse_i64(s, base) match {
        Ok(p) => if p.0 < -128i64 or p.0 > 127i64 { Err(ConvError.Overflow) } else { Ok(p) },
        Err(e) => Err(e)
    }
}

// Parse an i16. Returns (value, bytes_consumed) with value guaranteed in [-32768, 32767].
pub fn parse_i16(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    return parse_i64(s, base) match {
        Ok(p) => if p.0 < -32768 or p.0 > 32767 { Err(ConvError.Overflow) } else { Ok(p) },
        Err(e) => Err(e)
    }
}

// Parse an i32. Returns (value, bytes_consumed) with value guaranteed in [-2147483648, 2147483647].
pub fn parse_i32(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    return parse_i64(s, base) match {
        Ok(p) => if p.0 < -2147483648 or p.0 > 2147483647 { Err(ConvError.Overflow) } else { Ok(p) },
        Err(e) => Err(e)
    }
}

// Parse an isize. Returns (value, bytes_consumed).
pub fn parse_isize(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    return parse_i64(s, base)
}

// =============================================================================
// Bool
// =============================================================================

// Format a boolean into buf ("true" or "false"). Returns bytes written.
pub fn format_bool(val: bool, buf: u8[]) Result(usize, ConvError) {
    if val {
        if buf.len < 4 { return Err(ConvError.BufferTooSmall) }
        buf[0] = b't'
        buf[1] = b'r'
        buf[2] = b'u'
        buf[3] = b'e'
        return Ok(4usize)
    }
    if buf.len < 5 { return Err(ConvError.BufferTooSmall) }
    buf[0] = b'f'
    buf[1] = b'a'
    buf[2] = b'l'
    buf[3] = b's'
    buf[4] = b'e'
    return Ok(5usize)
}

// Parse a boolean from a byte buffer. Returns (value, bytes_consumed).
pub fn parse_bool(s: u8[]) Result((bool, usize), ConvError) {
    if s.len >= 4 and s[0] == b't' and s[1] == b'r' and s[2] == b'u' and s[3] == b'e' {
        return Ok((true, 4usize))
    }
    if s.len >= 5 and s[0] == b'f' and s[1] == b'a' and s[2] == b'l' and s[3] == b's' and s[4] == b'e' {
        return Ok((false, 5usize))
    }
    return Err(ConvError.InvalidInput)
}

// =============================================================================
// Tests
// =============================================================================

test "format_u64 zero" {
    let buf = [0u8; 64]
    const len = format_u64(0, buf).unwrap()
    assert_eq(len, 1usize, "zero should be 1 byte")
    assert_eq(buf[0], b'0', "zero should be '0'")
}

test "format_u64 decimal" {
    let buf = [0u8; 64]
    const len = format_u64(12345, buf).unwrap()
    assert_eq(len, 5usize, "12345 is 5 digits")
    assert_eq(buf[0], b'1', "first digit")
    assert_eq(buf[1], b'2', "second digit")
    assert_eq(buf[2], b'3', "third digit")
    assert_eq(buf[3], b'4', "fourth digit")
    assert_eq(buf[4], b'5', "fifth digit")
}

test "format_u64 hex" {
    let buf = [0u8; 64]
    const len = format_u64(255, buf, 16).unwrap()
    assert_eq(len, 2usize, "0xff is 2 hex digits")
    assert_eq(buf[0], b'f', "first hex digit")
    assert_eq(buf[1], b'f', "second hex digit")
}

test "format_u64 binary" {
    let buf = [0u8; 64]
    const len = format_u64(10, buf, 2).unwrap()
    assert_eq(len, 4usize, "10 in binary is 4 digits")
    assert_eq(buf[0], b'1', "bit 3")
    assert_eq(buf[1], b'0', "bit 2")
    assert_eq(buf[2], b'1', "bit 1")
    assert_eq(buf[3], b'0', "bit 0")
}

test "format_u64 octal" {
    let buf = [0u8; 64]
    const len = format_u64(8, buf, 8).unwrap()
    assert_eq(len, 2usize, "8 in octal is 10")
    assert_eq(buf[0], b'1', "octal digit 1")
    assert_eq(buf[1], b'0', "octal digit 0")
}

test "format_u64 u64 max" {
    let buf = [0u8; 64]
    const len = format_u64(0xFFFF_FFFF_FFFF_FFFF, buf).unwrap()
    assert_eq(len, 20usize, "u64 max is 20 decimal digits")
}

test "format_u64 invalid base" {
    let buf = [0u8; 64]
    const result = format_u64(42, buf, 1)
    assert_true(result.is_err(), "base 1 should fail")
}

test "format_u64 buffer too small" {
    let buf = [0u8; 2]
    const result = format_u64(12345, buf)
    assert_true(result.is_err(), "2-byte buf too small for 12345")
}

test "format_i64 positive" {
    let buf = [0u8; 64]
    const len = format_i64(42, buf).unwrap()
    assert_eq(len, 2usize, "42 is 2 digits")
    assert_eq(buf[0], b'4', "first digit")
    assert_eq(buf[1], b'2', "second digit")
}

test "format_i64 zero" {
    let buf = [0u8; 64]
    const len = format_i64(0, buf).unwrap()
    assert_eq(len, 1usize, "0 is 1 digit")
    assert_eq(buf[0], b'0', "zero")
}

test "format_i64 negative" {
    let buf = [0u8; 64]
    const len = format_i64(-123, buf).unwrap()
    assert_eq(len, 4usize, "-123 is 4 chars")
    assert_eq(buf[0], b'-', "minus sign")
    assert_eq(buf[1], b'1', "first digit")
    assert_eq(buf[2], b'2', "second digit")
    assert_eq(buf[3], b'3', "third digit")
}

test "format_i64 i64 min" {
    let buf = [0u8; 64]
    const min_val: i64 = 0 - 9223372036854775807 - 1
    const len = format_i64(min_val, buf).unwrap()
    assert_eq(len, 20usize, "i64 min is 20 chars including minus")
    assert_eq(buf[0], b'-', "minus sign")
}

test "parse_u64 basic" {
    const input = "12345"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_u64(s).unwrap()
    assert_eq(p.0, 12345u64, "value should be 12345")
    assert_eq(p.1, 5usize, "should consume 5 bytes")
}

test "parse_u64 hex" {
    const input = "ff"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_u64(s, 16).unwrap()
    assert_eq(p.0, 255u64, "0xff = 255")
    assert_eq(p.1, 2usize, "consumed 2 bytes")
}

test "parse_u64 uppercase hex" {
    const input = "FF"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_u64(s, 16).unwrap()
    assert_eq(p.0, 255u64, "0xFF = 255")
}

test "parse_u64 partial" {
    const input = "123abc"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_u64(s).unwrap()
    assert_eq(p.0, 123u64, "parsed value")
    assert_eq(p.1, 3usize, "consumed 3 decimal digits")
}

test "parse_u64 empty returns error" {
    const input = ""
    const s = slice_from_raw_parts(input.ptr, input.len)
    const result = parse_u64(s)
    assert_true(result.is_err(), "empty should return error")
}

test "parse_u64 no digits returns error" {
    const input = "abc"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const result = parse_u64(s)
    assert_true(result.is_err(), "non-digit should return error")
}

test "parse_u64 zero" {
    const input = "0"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_u64(s).unwrap()
    assert_eq(p.0, 0u64, "value is 0")
    assert_eq(p.1, 1usize, "consumed 1 byte")
}

test "parse_i64 positive" {
    const input = "42"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_i64(s).unwrap()
    const val: i64 = p.0 as i64
    assert_eq(val, 42i64, "value is 42")
    assert_eq(p.1, 2usize, "consumed 2 bytes")
}

test "parse_i64 negative" {
    const input = "-123"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_i64(s).unwrap()
    const val: i64 = p.0 as i64
    assert_eq(val, -123i64, "value is -123")
    assert_eq(p.1, 4usize, "consumed 4 bytes")
}

test "parse_i64 just minus returns error" {
    const input = "-"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const result = parse_i64(s)
    assert_true(result.is_err(), "bare minus should return error")
}

test "parse_i64 zero" {
    const input = "0"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_i64(s).unwrap()
    const val: i64 = p.0 as i64
    assert_eq(val, 0i64, "value is 0")
}

test "format_bool true" {
    let buf = [0u8; 8]
    const len = format_bool(true, buf).unwrap()
    assert_eq(len, 4usize, "true is 4 bytes")
    assert_eq(buf[0], b't', "t")
    assert_eq(buf[1], b'r', "r")
    assert_eq(buf[2], b'u', "u")
    assert_eq(buf[3], b'e', "e")
}

test "format_bool false" {
    let buf = [0u8; 8]
    const len = format_bool(false, buf).unwrap()
    assert_eq(len, 5usize, "false is 5 bytes")
    assert_eq(buf[0], b'f', "f")
    assert_eq(buf[1], b'a', "a")
    assert_eq(buf[2], b'l', "l")
    assert_eq(buf[3], b's', "s")
    assert_eq(buf[4], b'e', "e")
}

test "parse_bool true" {
    const input = "true"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_bool(s).unwrap()
    assert_eq(p.0, true, "value is true")
    assert_eq(p.1, 4usize, "consumed 4 bytes")
}

test "parse_bool false" {
    const input = "false"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_bool(s).unwrap()
    assert_eq(p.0, false, "value is false")
    assert_eq(p.1, 5usize, "consumed 5 bytes")
}

test "parse_bool invalid returns error" {
    const input = "yes"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const result = parse_bool(s)
    assert_true(result.is_err(), "invalid should return error")
}

test "format_u64 roundtrip" {
    let buf = [0u8; 64]
    const len = format_u64(9876543210, buf).unwrap()
    const p = parse_u64(buf[0..len]).unwrap()
    assert_eq(p.0, 9876543210u64, "roundtrip value")
}

test "format_i64 roundtrip negative" {
    let buf = [0u8; 64]
    const len = format_i64(-9876543210, buf).unwrap()
    const p = parse_i64(buf[0..len]).unwrap()
    const val: i64 = p.0 as i64
    assert_eq(val, -9876543210i64, "negative roundtrip value")
}

test "parse_u8 valid" {
    const input = "200"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_u8(s).unwrap()
    assert_eq(p.0, 200u64, "value is 200")
}

test "parse_u8 overflow" {
    const input = "256"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const result = parse_u8(s)
    assert_true(result.is_err(), "256 overflows u8")
}

test "parse_i8 valid" {
    const input = "-128"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_i8(s).unwrap()
    const val: i64 = p.0 as i64
    assert_eq(val, -128i64, "value is -128")
}

test "parse_i8 overflow" {
    const input = "128"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const result = parse_i8(s)
    assert_true(result.is_err(), "128 overflows i8")
}
