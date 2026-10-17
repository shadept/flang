// Zero-allocation conversion functions.
// Buffer-based formatting and parsing for integers, floats and booleans.

import std.option
import std.result
import std.test

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

// Format an unsigned 64-bit integer into `buf`. Returns bytes written.
// Supports bases 2–16. Lowercase a–f for hex.
//
// Required buffer capacity (upper bounds):
//   base 10:  20 bytes  (u64 max = 18_446_744_073_709_551_615)
//   base 16:  16 bytes
//   base 8:   22 bytes
//   base 2:   64 bytes
// When unsure, a 64-byte buffer fits any supported base. Returns `Err(BufferTooSmall)` if `buf` is
// too short.
pub fn format_u64(val: u64, buf: u8[], base: u8 = 10) Result(usize, ConvError) {
    if base < 2 or base > 16 {
        return Err(ConvError.InvalidBase)
    }

    if val == 0 {
        if buf.len < 1 {
            return Err(ConvError.BufferTooSmall)
        }
        buf[0] = '0'
        return Ok(1usize)
    }

    // Extract digits right-to-left into temp buffer
    let tmp = [0u8; 64]
    let pos = tmp.len
    const base_u64 = base as u64

    while val != 0 {
        const digit = (val % base_u64) as u8
        val = val / base_u64
        pos = pos - 1
        tmp[pos] = if digit < 10 {
            '0' + digit
        } else {
            'a' - 10 + digit
        }
    }

    const len = 64 - pos
    if buf.len < len {
        return Err(ConvError.BufferTooSmall)
    }

    // Copy to front of caller buffer
    for i in 0..len {
        buf[i] = tmp[pos + i]
    }

    return Ok(len)
}

// Format a signed 64-bit integer into `buf`. Returns bytes written.
// Supports bases 2–16. Lowercase a–f for hex. A leading '-' is emitted for
// negative values in every base (the absolute magnitude is rendered in the requested base - no
// two's-complement bit pattern).
//
// Required buffer capacity (upper bounds, includes room for the sign):
//   base 10:  21 bytes
//   base 16:  17 bytes
//   base 8:   23 bytes
//   base 2:   65 bytes
// A 65-byte buffer fits any supported base. Returns `Err(BufferTooSmall)` if `buf` is too short.
pub fn format_i64(val: i64, buf: u8[], base: u8 = 10) Result(usize, ConvError) {
    if base < 2 or base > 16 {
        return Err(ConvError.InvalidBase)
    }

    const is_negative = val < 0
    let abs_val = if is_negative { (0 - val) as u64 } else { val as u64 }

    let offset = 0
    if is_negative {
        if buf.len < 2 {
            return Err(ConvError.BufferTooSmall)
        }
        buf[0] = '-'
        offset = 1
    }

    const result = format_u64(abs_val, buf[offset..], base)
    return result match {
        Ok(written) => Ok(offset + written)
        Err(e) => Err(e)
    }
}

// Format an f64 into `buf` as `[-]int[.frac]`. Returns bytes written.
//
// `precision` caps the fractional digits (default 6). When `trim_zeros` is true, trailing zeros are
// removed and the decimal point is omitted if the fractional part collapses to empty.
//
// Required buffer capacity: `23 + precision` bytes in the worst case (1 sign + 21 integer digits +
// '.' + precision fractional digits). The default precision of 6 fits in 29 bytes; 48 bytes is a
// safe default for any precision up to ~25. Returns `Err(BufferTooSmall)` if `buf` is short.
//
// Caveat: the integer portion is extracted via `as u64`, so values whose magnitude exceeds 2^64
// aren't representable and will truncate. Non-finite inputs (NaN, infinity) aren't handled
// specially.
pub fn format_f64(
    val: f64,
    buf: u8[],
    precision: usize = 6,
    trim_zeros: bool = true,
) Result(usize, ConvError) {
    let abs_val = val
    let negative = false
    if val < 0.0 {
        negative = true
        abs_val = 0.0 - val
    }

    // Round by adding 0.5 * 10^-precision so truncation rounds correctly.
    let round = 0.5
    for r in 0..precision {
        round = round / 10.0
    }
    abs_val = abs_val + round

    let int_part = abs_val as u64
    let int_buf = [0u8; 21]
    const int_len = format_u64(int_part, int_buf).unwrap()

    // Fractional digits.
    let frac = abs_val - (int_part as f64)
    let frac_buf = [0u8; 20]
    let frac_len: usize = 0
    for i in 0..precision {
        frac = frac * 10.0
        let digit: u64 = frac as u64
        frac_buf[frac_len] = '0' + digit as u8
        frac_len = frac_len + 1
        frac = frac - (digit as f64)
    }

    if trim_zeros {
        while frac_len != 0 and frac_buf[frac_len - 1] == '0' {
            frac_len = frac_len - 1
        }
    }

    let needed: usize = int_len + frac_len
    if negative {
        needed = needed + 1
    }
    if frac_len > 0 {
        needed = needed + 1
    } // '.'
    if buf.len < needed {
        return Err(ConvError.BufferTooSmall)
    }

    let pos: usize = 0
    if negative {
        buf[pos] = '-'
        pos = pos + 1
    }
    for j in 0..int_len {
        buf[pos] = int_buf[j]
        pos = pos + 1
    }
    if frac_len > 0 {
        buf[pos] = '.'
        pos = pos + 1
        for j in 0..frac_len {
            buf[pos] = frac_buf[j]
            pos = pos + 1
        }
    }

    return Ok(pos)
}

// The f64's IEEE-754 bit pattern.
fn f64_bits(v: f64) u64 {
    let p = &v
    let q = p as &u64
    return q.*
}

fn write_word(buf: u8[], w: String) Result(usize, ConvError) {
    if buf.len < w.len {
        return Err(ConvError.BufferTooSmall)
    }
    for i in 0..w.len {
        buf[i] = w[i]
    }
    return Ok(w.len)
}

// Format an f64 as a C99 hexadecimal floating literal:
// `[-]0x1.<mant>p<±exp>` (normal), `[-]0x0.<mant>p-1022` (denormal),
// `[-]0x0p+0` (zero); non-finite values write `nan` / `inf` / `-inf`.
//
// This is the EXACT representation: the text encodes the bit pattern directly (no decimal rounding
// anywhere), so parsing it - by a C99 compiler or `%a`-aware reader - recovers the identical value.
// Use it wherever a double must round-trip; `format_f64` and `format_f64_exp` are decimal
// renderings with finite precision.
//
// Required buffer capacity: 25 bytes worst case
// (sign + "0x1." + 13 mantissa nibbles + "p-1022").
pub fn format_f64_hex(val: f64, buf: u8[]) Result(usize, ConvError) {
    const bits = f64_bits(val)
    const negative = (bits >> 63) != 0
    const biased = ((bits >> 52) & 0x7FF) as i64
    let mant = bits & 0xF_FFFF_FFFF_FFFF

    if biased == 0x7FF {
        if mant != 0 {
            return write_word(buf, "nan")
        }
        if negative {
            return write_word(buf, "-inf")
        }
        return write_word(buf, "inf")
    }

    let tmp = [0u8; 32]
    let pos: usize = 0
    if negative {
        tmp[pos] = '-'
        pos = pos + 1
    }
    tmp[pos] = '0'
    pos = pos + 1
    tmp[pos] = 'x'
    pos = pos + 1

    // Leading digit and unbiased exponent: normals are 1.<mant> * 2^(b-1023), denormals 0.<mant> *
    // 2^-1022, zero is all-zero bits.
    let exp: i64 = 0
    if biased == 0 {
        tmp[pos] = '0'
        pos = pos + 1
        exp = 0 - 1022
        if mant == 0 {
            exp = 0
        }
    } else {
        tmp[pos] = '1'
        pos = pos + 1
        exp = biased - 1023
    }

    // Mantissa nibbles, high to low, trailing zeros trimmed.
    if mant != 0 {
        let nibbles = 13usize
        while nibbles > 0 and (mant & 0xF) == 0 {
            mant = mant >> 4
            nibbles = nibbles - 1
        }
        tmp[pos] = '.'
        pos = pos + 1
        let shift = (nibbles - 1) * 4
        for i in 0..nibbles {
            const n = ((mant >> ((shift - i * 4) as u64)) & 0xF) as u8
            tmp[pos] = if n < 10 { '0' + n } else { 'a' - 10 + n }
            pos = pos + 1
        }
    }

    tmp[pos] = 'p'
    pos = pos + 1
    if exp < 0 {
        tmp[pos] = '-'
        pos = pos + 1
        exp = 0 - exp
    } else {
        tmp[pos] = '+'
        pos = pos + 1
    }
    const elen = format_u64(exp as u64, tmp[pos..]).unwrap()
    pos = pos + elen

    if buf.len < pos {
        return Err(ConvError.BufferTooSmall)
    }
    copy_to(tmp[0..pos], buf)
    return Ok(pos)
}

// Format an f64 in scientific notation: `[-]d.<precision digits>e±XX`
// (two exponent digits minimum, more when needed); non-finite values write `nan` / `inf` / `-inf`.
// `uppercase` selects `E`.
//
// Decimal, not exact: the value is scaled by powers of ten in binary floating point, so the
// 16th-17th significant digit can be off by an ulp or two at extreme magnitudes. 17 significant
// digits are the most the scaling supports; a larger `precision` pads zeros. For a guaranteed
// round-trip use `format_f64_hex`.
//
// Required buffer capacity: `precision + 9` bytes
// (sign + digit + '.' + precision + 'e' + sign + 3 exponent digits).
pub fn format_f64_exp(
    val: f64,
    buf: u8[],
    precision: usize = 6,
    uppercase: bool = false,
) Result(usize, ConvError) {
    if val != val {
        return write_word(buf, "nan")
    }
    // Infinity test without a DBL_MAX literal: `v * 0.5 == v` holds only for 0 and the infinities
    // (a DBL_MAX-magnitude literal is the one shape the self-host parse_float can round to inf -
    // see lower.f).
    if val * 0.5 == val and val != 0.0 {
        return write_word(buf, if val > 0.0 { "inf" } else { "-inf" })
    }

    const negative = val < 0.0
    let d = if negative { 0.0 - val } else { val }

    // Scale into [1, 10). Big steps first so the whole walk is a handful of roundings (308 = 256 +
    // 32 + 16 + 4), plus single-step loops for the remainder and for values the big steps
    // overshoot.
    let exp: i64 = 0
    if d != 0.0 {
        if d >= 1e256 {
            d = d / 1e256
            exp = exp + 256
        }
        if d >= 1e128 {
            d = d / 1e128
            exp = exp + 128
        }
        if d >= 1e64 {
            d = d / 1e64
            exp = exp + 64
        }
        if d >= 1e32 {
            d = d / 1e32
            exp = exp + 32
        }
        if d >= 1e16 {
            d = d / 1e16
            exp = exp + 16
        }
        if d < 1e-255 {
            d = d * 1e256
            exp = exp - 256
        }
        if d < 1e-127 {
            d = d * 1e128
            exp = exp - 128
        }
        if d < 1e-63 {
            d = d * 1e64
            exp = exp - 64
        }
        if d < 1e-31 {
            d = d * 1e32
            exp = exp - 32
        }
        if d < 1e-15 {
            d = d * 1e16
            exp = exp - 16
        }
        while d >= 10.0 {
            d = d / 10.0
            exp = exp + 1
        }
        while d < 1.0 {
            d = d * 10.0
            exp = exp - 1
        }
    }

    // Half-ulp-of-last-digit rounding, then re-normalize the carry
    // (9.9999… rounds up to 10.0).
    const emit_digits = if precision > 16 { 16usize } else { precision }
    let round = 0.5
    for r in 0..emit_digits {
        round = round / 10.0
    }
    if d != 0.0 {
        d = d + round
        if d >= 10.0 {
            d = d / 10.0
            exp = exp + 1
        }
    }

    let tmp = [0u8; 64]
    let pos: usize = 0
    if negative {
        tmp[pos] = '-'
        pos = pos + 1
    }
    let lead = d as u64
    tmp[pos] = '0' + (lead as u8)
    pos = pos + 1
    d = d - (lead as f64)
    if precision > 0 {
        tmp[pos] = '.'
        pos = pos + 1
        for i in 0..precision {
            if i < emit_digits {
                d = d * 10.0
                const digit = d as u64
                tmp[pos] = '0' + (digit as u8)
                d = d - (digit as f64)
            } else {
                tmp[pos] = '0'
            }
            pos = pos + 1
        }
    }

    tmp[pos] = if uppercase { 'E' } else { 'e' }
    pos = pos + 1
    if exp < 0 {
        tmp[pos] = '-'
        pos = pos + 1
        exp = 0 - exp
    } else {
        tmp[pos] = '+'
        pos = pos + 1
    }
    if exp < 10 {
        tmp[pos] = '0'
        pos = pos + 1
    }
    const elen = format_u64(exp as u64, tmp[pos..]).unwrap()
    pos = pos + elen

    if buf.len < pos {
        return Err(ConvError.BufferTooSmall)
    }
    copy_to(tmp[0..pos], buf)
    return Ok(pos)
}

// =============================================================================
// Buffer → Integer
// =============================================================================

// Parse an unsigned 64-bit integer from a byte buffer. Returns (value, bytes_consumed).
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

    while consumed < s.len {
        const c = s[consumed]

        let digit_val: u64 = 0
        let valid = false

        if c >= '0' and c <= '9' {
            digit_val = (c - '0') as u64
            valid = digit_val < base_u64
        } else if c >= 'a' and c <= 'f' {
            digit_val = (c - 'a' + 10) as u64
            valid = digit_val < base_u64
        } else if c >= 'A' and c <= 'F' {
            digit_val = (c - 'A' + 10) as u64
            valid = digit_val < base_u64
        }

        if valid == false {
            break
        }

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

// Parse a signed 64-bit integer from a byte buffer. Returns (value, bytes_consumed).
pub fn parse_i64(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    if base < 2 or base > 16 {
        return Err(ConvError.InvalidBase)
    }
    if s.len == 0 {
        return Err(ConvError.InvalidInput)
    }

    let negative = false
    let offset = 0usize

    if s[0] == '-' {
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
        Ok(p) => if p.0 > 0xFF { Err(ConvError.Overflow) } else { Ok(p) }
        Err(e) => Err(e)
    }
}

// Parse a u16. Returns (value, bytes_consumed) with value guaranteed <= 0xFFFF.
pub fn parse_u16(s: u8[], base: u8 = 10) Result((u64, usize), ConvError) {
    return parse_u64(s, base) match {
        Ok(p) => if p.0 > 0xFFFF { Err(ConvError.Overflow) } else { Ok(p) }
        Err(e) => Err(e)
    }
}

// Parse a u32. Returns (value, bytes_consumed) with value guaranteed <= 0xFFFF_FFFF.
pub fn parse_u32(s: u8[], base: u8 = 10) Result((u64, usize), ConvError) {
    return parse_u64(s, base) match {
        Ok(p) => if p.0 > 0xFFFF_FFFF { Err(ConvError.Overflow) } else { Ok(p) }
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
        Ok(p) => if p.0 < -128i64 or p.0 > 127i64 { Err(ConvError.Overflow) } else { Ok(p) }
        Err(e) => Err(e)
    }
}

// Parse an i16. Returns (value, bytes_consumed) with value guaranteed in [-32768, 32767].
pub fn parse_i16(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    return parse_i64(s, base) match {
        Ok(p) => if p.0 < -32768 or p.0 > 32767 { Err(ConvError.Overflow) } else { Ok(p) }
        Err(e) => Err(e)
    }
}

// Parse an i32. Returns (value, bytes_consumed) with value guaranteed in [-2147483648, 2147483647].
pub fn parse_i32(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    return parse_i64(s, base) match {
        Ok(p) => if p.0 < -2147483648 or p.0 > 2147483647 { Err(ConvError.Overflow) } else { Ok(p) }
        Err(e) => Err(e)
    }
}

// Parse an isize. Returns (value, bytes_consumed).
pub fn parse_isize(s: u8[], base: u8 = 10) Result((i64, usize), ConvError) {
    return parse_i64(s, base)
}

// =============================================================================
// Buffer → Float
// =============================================================================

// Format an f64 as the shortest decimal text that reads back as the same value: `0.1`, `1e+21`,
// `5e-324`, `-0`. Plain decimal for exponents -7 through 20, `d.ddde+X` outside them (the layout of
// JavaScript's Number.toString). Non-finite values write `nan` / `inf` / `-inf`. A whole number
// carries no `.0`.
//
// Required buffer capacity: 32 bytes. Returns `Err(BufferTooSmall)` if `buf` is short.
pub fn format_f64_shortest(val: f64, buf: u8[]) Result(usize, ConvError) {
    if val != val {
        return write_word(buf, "nan")
    }
    const bits = f64_bits(val)
    const negative = (bits >> 63) != 0
    const biased = ((bits >> 52) & 0x7FF) as i64
    if biased == 0x7FF {
        return write_word(buf, if negative { "-inf" } else { "inf" })
    }
    if buf.len < 32 {
        return Err(ConvError.BufferTooSmall)
    }
    let mant = bits & 0xF_FFFF_FFFF_FFFF
    let exp = biased
    if exp == 0 {
        exp = 1
    } else {
        mant = mant | (1u64 << 52)
    }
    exp = exp - 1023

    let d = decimal()
    d.assign(mant)
    d.shift(exp - 52)
    d.round_shortest(mant, exp)
    return Ok(write_shortest(&d, negative, buf))
}

// Lay out `d`'s digits as format_f64_shortest describes.
fn write_shortest(d: &Decimal, negative: bool, buf: u8[]) usize {
    let pos: usize = 0
    if negative {
        buf[0] = '-'
        pos = 1
    }
    if d.nd == 0 {
        buf[pos] = '0'
        return pos + 1
    }
    const nd = d.nd
    const dp = d.dp
    if dp > 21 or dp <= -6 {
        buf[pos] = d.at(0)
        pos = pos + 1
        if nd > 1 {
            buf[pos] = '.'
            pos = pos + 1
            for i in 1..nd {
                buf[pos] = d.at(i)
                pos = pos + 1
            }
        }
        buf[pos] = 'e'
        buf[pos + 1] = if dp - 1 < 0 { '-' } else { '+' }
        pos = pos + 2
        const e = if dp - 1 < 0 { 1 - dp } else { dp - 1 }
        const n = format_u64(e as u64, buf[pos..buf.len]).unwrap()
        return pos + n
    }
    if dp <= 0 {
        buf[pos] = '0'
        buf[pos + 1] = '.'
        pos = pos + 2
        for _i in 0..0 - dp {
            buf[pos] = '0'
            pos = pos + 1
        }
        for i in 0..nd {
            buf[pos] = d.at(i)
            pos = pos + 1
        }
        return pos
    }
    for i in 0..dp {
        buf[pos] = if i < nd { d.at(i) } else { '0' }
        pos = pos + 1
    }
    if nd > dp {
        buf[pos] = '.'
        pos = pos + 1
        for i in dp..nd {
            buf[pos] = d.at(i)
            pos = pos + 1
        }
    }
    return pos
}

// Parse a 64-bit float from a byte buffer, correctly rounded (round half to even), as C's `strtod`
// does. Handles: optional sign, integer digits, fractional part, exponent (e/E). A value past the
// f64 range is an infinity, one below it zero. Returns (value, bytes_consumed).
pub fn parse_f64(s: u8[]) Result((f64, usize), ConvError) {
    const text = scan_float(s)?
    const fast = exact_f64(s, text)
    if fast.is_some() {
        return Ok((fast.unwrap(), text.end))
    }
    let d = decimal()
    d.read(s, text)
    return Ok((f64_from_bits(d.float_bits()), text.end))
}

// Where the parts of a float's text are.
type FloatText = struct {
    negative: bool
    // First digit, end of the digits and point, end of the whole text.
    digits_start: usize
    digits_end: usize
    end: usize
    exponent: i64
}

fn scan_float(s: u8[]) Result(FloatText, ConvError) {
    let pos: usize = 0
    let negative = false
    if s.len > 0 and (s[0] == '-' or s[0] == '+') {
        negative = s[0] == '-'
        pos = 1
    }
    const digits_start = pos
    let has_digits = false
    while pos < s.len and s[pos] >= '0' and s[pos] <= '9' {
        has_digits = true
        pos = pos + 1
    }
    if pos < s.len and s[pos] == '.' {
        pos = pos + 1
        while pos < s.len and s[pos] >= '0' and s[pos] <= '9' {
            has_digits = true
            pos = pos + 1
        }
    }
    if !has_digits {
        return Err(ConvError.InvalidInput)
    }
    const digits_end = pos
    let exponent: i64 = 0
    if pos < s.len and (s[pos] == 'e' or s[pos] == 'E') {
        pos = pos + 1
        let exp_negative = false
        if pos < s.len and (s[pos] == '-' or s[pos] == '+') {
            exp_negative = s[pos] == '-'
            pos = pos + 1
        }
        const exp_start = pos
        while pos < s.len and s[pos] >= '0' and s[pos] <= '9' {
            // Past 10000 the value is already infinite or zero.
            if exponent < 10000 {
                exponent = exponent * 10 + (s[pos] - '0') as i64
            }
            pos = pos + 1
        }
        if pos == exp_start {
            return Err(ConvError.InvalidInput)
        }
        if exp_negative {
            exponent = 0 - exponent
        }
    }
    return Ok(.{
        negative = negative,
        digits_start = digits_start,
        digits_end = digits_end,
        end = pos,
        exponent = exponent,
    })
}

// The value when its digits fit 2^53 and its power of ten 10^22: both are exact f64s, so one
// multiplication or division rounds once, correctly. Null otherwise.
fn exact_f64(s: u8[], text: FloatText) f64? {
    let mant: u64 = 0
    let digits: usize = 0
    let scale: i64 = 0
    let seen_point = false
    for i in text.digits_start..text.digits_end {
        const c = s[i]
        if c == '.' {
            seen_point = true
            continue
        }
        if mant == 0 and c == '0' {
            if seen_point {
                scale = scale - 1
            }
            continue
        }
        if digits == 19 {
            return null
        }
        mant = mant * 10 + (c - '0') as u64
        digits = digits + 1
        if seen_point {
            scale = scale - 1
        }
    }
    const e = text.exponent + scale
    const fits = mant <= (1u64 << 53) and e >= -22 and e <= 22
    if !fits {
        return null
    }
    let p = 1.0
    const abs_e = if e < 0 { 0 - e } else { e }
    for _i in 0..abs_e {
        p = p * 10.0
    }
    const m = mant as f64
    const v = if e < 0 { m / p } else { m * p }
    return Some(if text.negative { -v } else { v })
}

fn f64_from_bits(bits: u64) f64 {
    let b = bits
    let p = &b
    let q = p as &f64
    return q.*
}

// =============================================================================
// Exact decimal arithmetic - the slow path of float text, both directions
// =============================================================================

// The number 0.d[0]d[1]...d[nd-1] x 10^dp, digits as ASCII. 800 digits hold every finite f64
// exactly. The algorithm is Go's strconv `decimal`: shift by powers of two in decimal, round at a
// digit. ponytail: exact but O(digits) per shift; Ryu (format) and Eisel-Lemire (parse) are the
// fast paths if float text ever shows up in a profile.
const DECIMAL_DIGITS: i64 = 800

// The largest shift one pass takes: 9 << 60 still fits a u64.
const MAX_SHIFT: i64 = 60

type Decimal = struct {
    d: [u8; 800]
    nd: i64
    dp: i64
    neg: bool
    // Nonzero digits were dropped past `d[nd - 1]`.
    trunc: bool
}

fn decimal() Decimal {
    return .{ d = [0u8; 800], nd = 0, dp = 0, neg = false, trunc = false }
}

fn at(self: &Decimal, i: i64) u8 {
    return self.d[i as usize]
}

fn put(self: &Decimal, i: i64, c: u8) {
    self.d[i as usize] = c
}

fn assign(self: &Decimal, v: u64) {
    let buf = [0u8; 24]
    let n: i64 = 0
    let x = v
    while x > 0 {
        const q = x / 10
        buf[n as usize] = (x - 10 * q) as u8 + '0'
        n = n + 1
        x = q
    }
    self.nd = 0
    while n > 0 {
        n = n - 1
        self.put(self.nd, buf[n as usize])
        self.nd = self.nd + 1
    }
    self.dp = self.nd
    self.trim()
}

// Reads the digits `scan_float` found.
fn read(self: &Decimal, s: u8[], text: FloatText) {
    self.neg = text.negative
    let seen_point = false
    for i in text.digits_start..text.digits_end {
        const c = s[i]
        if c == '.' {
            seen_point = true
            self.dp = self.nd
            continue
        }
        if c == '0' and self.nd == 0 {
            self.dp = self.dp - 1
            continue
        }
        if self.nd < DECIMAL_DIGITS {
            self.put(self.nd, c)
            self.nd = self.nd + 1
        } else if c != '0' {
            self.trunc = true
        }
    }
    if !seen_point {
        self.dp = self.nd
    }
    self.dp = self.dp + text.exponent
    self.trim()
}

fn trim(self: &Decimal) {
    while self.nd > 0 and self.at(self.nd - 1) == '0' {
        self.nd = self.nd - 1
    }
    if self.nd == 0 {
        self.dp = 0
    }
}

// Multiplies by 2^k, a negative `k` dividing.
fn shift(self: &Decimal, k: i64) {
    if self.nd == 0 {
        return
    }
    let left = k
    while left > MAX_SHIFT {
        self.left_shift(MAX_SHIFT as u64)
        left = left - MAX_SHIFT
    }
    while left < 0 - MAX_SHIFT {
        self.right_shift(MAX_SHIFT as u64)
        left = left + MAX_SHIFT
    }
    if left > 0 {
        self.left_shift(left as u64)
    } else if left < 0 {
        self.right_shift((0 - left) as u64)
    }
}

fn right_shift(self: &Decimal, k: u64) {
    let r: i64 = 0
    let w: i64 = 0
    let n: u64 = 0
    while (n >> k) == 0 {
        if r >= self.nd {
            if n == 0 {
                self.nd = 0
                return
            }
            while (n >> k) == 0 {
                n = n * 10
                r = r + 1
            }
            break
        }
        n = n * 10 + (self.at(r) - '0') as u64
        r = r + 1
    }
    self.dp = self.dp - (r - 1)

    const mask = (1u64 << k) - 1
    while r < self.nd {
        const c = (self.at(r) - '0') as u64
        const dig = n >> k
        n = n & mask
        self.put(w, dig as u8 + '0')
        w = w + 1
        n = n * 10 + c
        r = r + 1
    }
    while n > 0 {
        const dig = n >> k
        n = n & mask
        if w < DECIMAL_DIGITS {
            self.put(w, dig as u8 + '0')
            w = w + 1
        } else if dig > 0 {
            self.trunc = true
        }
        n = n * 10
    }
    self.nd = w
    self.trim()
}

// Digits are written from the end, `delta` past the old end: at least as many as the shift can add,
// since log10(2) < 0.30103. The unused leading slots are then closed up.
fn left_shift(self: &Decimal, k: u64) {
    const delta = (k as i64 * 30103) / 100000 + 1
    const end = self.nd + delta
    let r = self.nd
    let w = end
    let n: u64 = 0
    while r > 0 {
        r = r - 1
        n = n + (((self.at(r) - '0') as u64) << k)
        w = w - 1
        self.put_digit(w, n % 10)
        n = n / 10
    }
    while n > 0 {
        w = w - 1
        self.put_digit(w, n % 10)
        n = n / 10
    }
    const kept_end = if end < DECIMAL_DIGITS { end } else { DECIMAL_DIGITS }
    for i in w..kept_end {
        self.put(i - w, self.at(i))
    }
    self.dp = self.dp + (end - w) - self.nd
    self.nd = kept_end - w
    self.trim()
}

// Writes digit `v` at `i`, or records it as dropped past the last slot.
fn put_digit(self: &Decimal, i: i64, v: u64) {
    if i < DECIMAL_DIGITS {
        self.put(i, v as u8 + '0')
    } else if v != 0 {
        self.trunc = true
    }
}

// Whether chopping at `nd` digits rounds up: past half, or exactly half and the kept digit odd.
fn should_round_up(self: &Decimal, nd: i64) bool {
    if nd < 0 or nd >= self.nd {
        return false
    }
    if self.at(nd) == '5' and nd + 1 == self.nd {
        if self.trunc {
            return true
        }
        return nd > 0 and (self.at(nd - 1) - '0') % 2 != 0
    }
    return self.at(nd) >= '5'
}

fn round(self: &Decimal, nd: i64) {
    if self.should_round_up(nd) {
        self.round_up(nd)
    } else {
        self.round_down(nd)
    }
}

fn round_down(self: &Decimal, nd: i64) {
    if nd < 0 or nd >= self.nd {
        return
    }
    self.nd = nd
    self.trim()
}

fn round_up(self: &Decimal, nd: i64) {
    if nd < 0 or nd >= self.nd {
        return
    }
    let i = nd - 1
    while i >= 0 {
        if self.at(i) < '9' {
            self.put(i, self.at(i) + 1)
            self.nd = i + 1
            return
        }
        i = i - 1
    }
    self.put(0, '1')
    self.nd = 1
    self.dp = self.dp + 1
}

// The integer part, rounded at the point.
fn rounded_integer(self: &Decimal) u64 {
    if self.dp > 20 {
        return 0xFFFF_FFFF_FFFF_FFFF
    }
    let n: u64 = 0
    let i: i64 = 0
    while i < self.dp and i < self.nd {
        n = n * 10 + (self.at(i) - '0') as u64
        i = i + 1
    }
    while i < self.dp {
        n = n * 10
        i = i + 1
    }
    if self.should_round_up(self.dp) {
        n = n + 1
    }
    return n
}

// The shift that brings `dp` digits of point toward zero without overshooting.
fn power_step(dp: i64) i64 {
    return dp match {
        0 => 1
        1 => 3
        2 => 6
        3 => 9
        4 => 13
        5 => 16
        6 => 19
        7 => 23
        8 => 26
        else => 27
    }
}

// The nearest f64's bits, rounding half to even.
fn float_bits(self: &Decimal) u64 {
    const sign = if self.neg { 1u64 << 63 } else { 0u64 }
    if self.nd == 0 or self.dp < -330 {
        return sign
    }
    const infinity = sign | (0x7FFu64 << 52)
    if self.dp > 310 {
        return infinity
    }

    // Scale to [0.5, 1) by powers of two, then into the f64 range [1, 2).
    let exp: i64 = 0
    while self.dp > 0 {
        const n = power_step(self.dp)
        self.shift(0 - n)
        exp = exp + n
    }
    while self.dp < 0 or (self.dp == 0 and self.at(0) < '5') {
        const n = power_step(0 - self.dp)
        self.shift(n)
        exp = exp - n
    }
    exp = exp - 1

    // Below the smallest normal exponent the value is subnormal: fewer mantissa bits.
    if exp < -1022 {
        const n = -1022 - exp
        self.shift(0 - n)
        exp = exp + n
    }
    if exp + 1023 >= 0x7FF {
        return infinity
    }

    self.shift(53)
    let mant = self.rounded_integer()
    if mant == 1u64 << 53 {
        mant = mant >> 1
        exp = exp + 1
        if exp + 1023 >= 0x7FF {
            return infinity
        }
    }
    const is_subnormal = (mant & (1u64 << 52)) == 0
    const biased = if is_subnormal { 0 } else { exp + 1023 }
    return sign | ((biased as u64) << 52) | (mant & 0xF_FFFF_FFFF_FFFF)
}

// Rounds this decimal - the exact value of the f64 `mant` x 2^(exp - 52) - to the fewest digits
// that still read back as that f64: any decimal strictly between the midpoints to its neighbours,
// or on one when `mant` is even (round half to even then lands on it).
fn round_shortest(self: &Decimal, mant: u64, exp: i64) {
    if mant == 0 {
        self.nd = 0
        return
    }
    // Already shortest when the gap to the next shorter decimal exceeds the f64 spacing (log2(10) >
    // 3.32).
    const min_exp: i64 = -1022
    if exp > min_exp and 332 * (self.dp - self.nd) >= 100 * (exp - 52) {
        return
    }

    let upper = decimal()
    upper.assign(mant * 2 + 1)
    upper.shift(exp - 52 - 1)

    const lower_is_wider = mant > (1u64 << 52) or exp == min_exp
    const mant_lo = if lower_is_wider { mant - 1 } else { mant * 2 - 1 }
    const exp_lo = if lower_is_wider { exp } else { exp - 1 }
    let lower = decimal()
    lower.assign(mant_lo * 2 + 1)
    lower.shift(exp_lo - 52 - 1)

    const inclusive = mant % 2 == 0

    // 0: the digits so far equal upper's; 1: they differ by one, then 9s against upper's 0s; 2:
    // rounding up stays below upper.
    let upper_delta: u8 = 0
    let ui: i64 = 0
    loop {
        const mi = ui - upper.dp + self.dp
        if mi >= self.nd {
            return
        }
        const li = ui - upper.dp + lower.dp
        const l = if li >= 0 and li < lower.nd { lower.at(li) } else { '0' }
        const m = if mi >= 0 { self.at(mi) } else { '0' }
        const u = if ui < upper.nd { upper.at(ui) } else { '0' }

        const ok_down = l != m or (inclusive and li + 1 == lower.nd)
        if upper_delta == 0 and m + 1 < u {
            upper_delta = 2
        } else if upper_delta == 0 and m != u {
            upper_delta = 1
        } else if upper_delta == 1 and (m != '9' or u != '0') {
            upper_delta = 2
        }
        const ok_up = upper_delta > 0 and (inclusive or upper_delta > 1 or ui + 1 < upper.nd)

        if ok_down and ok_up {
            self.round(mi + 1)
            return
        }
        if ok_down {
            self.round_down(mi + 1)
            return
        }
        if ok_up {
            self.round_up(mi + 1)
            return
        }
        ui = ui + 1
    }
}

// =============================================================================
// Bool
// =============================================================================

// Format a boolean into buf ("true" or "false"). Returns bytes written.
pub fn format_bool(val: bool, buf: u8[]) Result(usize, ConvError) {
    if val {
        if buf.len < 4 {
            return Err(ConvError.BufferTooSmall)
        }
        buf[0] = 't'
        buf[1] = 'r'
        buf[2] = 'u'
        buf[3] = 'e'
        return Ok(4usize)
    }
    if buf.len < 5 {
        return Err(ConvError.BufferTooSmall)
    }
    buf[0] = 'f'
    buf[1] = 'a'
    buf[2] = 'l'
    buf[3] = 's'
    buf[4] = 'e'
    return Ok(5usize)
}

// Parse a boolean from a byte buffer. Returns (value, bytes_consumed).
pub fn parse_bool(s: u8[]) Result((bool, usize), ConvError) {
    if s.len >= 4 and s[0] == 't' and s[1] == 'r' and s[2] == 'u' and s[3] == 'e' {
        return Ok((true, 4usize))
    }
    if s.len >= 5 and s[0] == 'f' and s[1] == 'a' and s[2] == 'l' and s[3] == 's' and s[4] == 'e' {
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
    assert_eq(buf[0], '0', "zero should be '0'")
}

test "format_u64 decimal" {
    let buf = [0u8; 64]
    const len = format_u64(12345, buf).unwrap()
    assert_eq(len, 5usize, "12345 is 5 digits")
    assert_eq(buf[0], '1', "first digit")
    assert_eq(buf[1], '2', "second digit")
    assert_eq(buf[2], '3', "third digit")
    assert_eq(buf[3], '4', "fourth digit")
    assert_eq(buf[4], '5', "fifth digit")
}

test "format_u64 hex" {
    let buf = [0u8; 64]
    const len = format_u64(255, buf, 16).unwrap()
    assert_eq(len, 2usize, "0xff is 2 hex digits")
    assert_eq(buf[0], 'f', "first hex digit")
    assert_eq(buf[1], 'f', "second hex digit")
}

test "format_u64 binary" {
    let buf = [0u8; 64]
    const len = format_u64(10, buf, 2).unwrap()
    assert_eq(len, 4usize, "10 in binary is 4 digits")
    assert_eq(buf[0], '1', "bit 3")
    assert_eq(buf[1], '0', "bit 2")
    assert_eq(buf[2], '1', "bit 1")
    assert_eq(buf[3], '0', "bit 0")
}

test "format_u64 octal" {
    let buf = [0u8; 64]
    const len = format_u64(8, buf, 8).unwrap()
    assert_eq(len, 2usize, "8 in octal is 10")
    assert_eq(buf[0], '1', "octal digit 1")
    assert_eq(buf[1], '0', "octal digit 0")
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
    assert_eq(buf[0], '4', "first digit")
    assert_eq(buf[1], '2', "second digit")
}

test "format_i64 zero" {
    let buf = [0u8; 64]
    const len = format_i64(0, buf).unwrap()
    assert_eq(len, 1usize, "0 is 1 digit")
    assert_eq(buf[0], '0', "zero")
}

test "format_i64 negative" {
    let buf = [0u8; 64]
    const len = format_i64(-123, buf).unwrap()
    assert_eq(len, 4usize, "-123 is 4 chars")
    assert_eq(buf[0], '-', "minus sign")
    assert_eq(buf[1], '1', "first digit")
    assert_eq(buf[2], '2', "second digit")
    assert_eq(buf[3], '3', "third digit")
}

test "format_i64 i64 min" {
    let buf = [0u8; 64]
    const min_val: i64 = 0 - 9223372036854775807 - 1
    const len = format_i64(min_val, buf).unwrap()
    assert_eq(len, 20usize, "i64 min is 20 chars including minus")
    assert_eq(buf[0], '-', "minus sign")
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
    assert_eq(buf[0], 't', "t")
    assert_eq(buf[1], 'r', "r")
    assert_eq(buf[2], 'u', "u")
    assert_eq(buf[3], 'e', "e")
}

test "format_bool false" {
    let buf = [0u8; 8]
    const len = format_bool(false, buf).unwrap()
    assert_eq(len, 5usize, "false is 5 bytes")
    assert_eq(buf[0], 'f', "f")
    assert_eq(buf[1], 'a', "a")
    assert_eq(buf[2], 'l', "l")
    assert_eq(buf[3], 's', "s")
    assert_eq(buf[4], 'e', "e")
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

test "parse_f64 integer" {
    const input = "42"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_f64(s).unwrap()
    assert_eq(p.0, 42.0, "value should be 42.0")
    assert_eq(p.1, 2usize, "consumed 2 bytes")
}

test "parse_f64 decimal" {
    const input = "3.14"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_f64(s).unwrap()
    assert_true(p.0 > 3.13 and p.0 < 3.15, "value should be ~3.14")
    assert_eq(p.1, 4usize, "consumed 4 bytes")
}

test "parse_f64 negative" {
    const input = "-1.5"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_f64(s).unwrap()
    assert_eq(p.0, -1.5, "value should be -1.5")
    assert_eq(p.1, 4usize, "consumed 4 bytes")
}

test "parse_f64 exponent" {
    const input = "1e3"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_f64(s).unwrap()
    assert_eq(p.0, 1000.0, "1e3 should be 1000")
    assert_eq(p.1, 3usize, "consumed 3 bytes")
}

test "parse_f64 negative exponent" {
    const input = "5e-2"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_f64(s).unwrap()
    assert_true(p.0 > 0.049 and p.0 < 0.051, "5e-2 should be ~0.05")
    assert_eq(p.1, 4usize, "consumed 4 bytes")
}

test "parse_f64 zero" {
    const input = "0"
    const s = slice_from_raw_parts(input.ptr, input.len)
    const p = parse_f64(s).unwrap()
    assert_eq(p.0, 0.0, "value should be 0.0")
    assert_eq(p.1, 1usize, "consumed 1 byte")
}

test "parse_f64 empty returns error" {
    const input = ""
    const s = slice_from_raw_parts(input.ptr, input.len)
    const result = parse_f64(s)
    assert_true(result.is_err(), "empty should return error")
}

fn shortest_is(v: f64, expected: String) bool {
    let buf = [0u8; 32]
    const n = format_f64_shortest(v, buf).unwrap()
    return buf[0..n] as String == expected
}

// The f64 the shortest text of `v` reads back as.
fn reread(v: f64) f64 {
    let buf = [0u8; 32]
    const n = format_f64_shortest(v, buf).unwrap()
    return parse_f64(buf[0..n]).unwrap().0
}

fn parsed(s: String) f64 {
    return parse_f64(s.as_raw_bytes()).unwrap().0
}

test "format_f64_shortest writes the fewest digits that read back" {
    assert_true(shortest_is(0.1, "0.1"), "0.1")
    assert_true(shortest_is(0.1 + 0.2, "0.30000000000000004"), "0.1 + 0.2")
    assert_true(shortest_is(1.0 / 3.0, "0.3333333333333333"), "a third")
    assert_true(shortest_is(100.0, "100"), "whole")
    assert_true(shortest_is(123.456, "123.456"), "fraction")
    assert_true(shortest_is(1e21, "1e+21"), "large")
    assert_true(shortest_is(1e20, "100000000000000000000"), "below the exponent cutoff")
    assert_true(shortest_is(1e-7, "1e-7"), "small")
    assert_true(shortest_is(0.000001, "0.000001"), "above the exponent cutoff")
    assert_true(shortest_is(f64_from_bits(1), "5e-324"), "smallest subnormal")
    assert_true(
        shortest_is(f64_from_bits(0x7FEF_FFFF_FFFF_FFFF), "1.7976931348623157e+308"),
        "largest finite",
    )
    assert_true(shortest_is(0.0, "0"), "zero")
    assert_true(shortest_is(-0.0, "-0"), "negative zero")
    assert_true(shortest_is(-2.5, "-2.5"), "negative")
}

test "parse_f64 rounds correctly where repeated multiplication does not" {
    assert_eq(f64_bits(parsed("0.1")), f64_bits(0.1), "0.1")
    assert_eq(f64_bits(parsed("1.7976931348623157e308")), 0x7FEF_FFFF_FFFF_FFFF, "largest finite")
    assert_eq(f64_bits(parsed("4.9406564584124654e-324")), 1u64, "smallest subnormal")
    assert_eq(
        f64_bits(parsed("2.2250738585072011e-308")),
        0x000F_FFFF_FFFF_FFFF,
        "largest subnormal",
    )
    assert_eq(f64_bits(parsed("9007199254740993")), 0x4340_0000_0000_0000, "2^53 + 1 ties to even")
    assert_eq(f64_bits(parsed("1e400")), 0x7FF0_0000_0000_0000, "overflow is infinity")
    assert_eq(f64_bits(parsed("1e-400")), 0u64, "underflow is zero")
    assert_eq(f64_bits(parsed("-0.0")), 0x8000_0000_0000_0000, "negative zero")
    assert_eq(
        parse_f64("12.5e1x".as_raw_bytes()).unwrap().1,
        6 as usize,
        "consumes the float prefix",
    )
    assert_true(parse_f64("1e".as_raw_bytes()).is_err(), "exponent needs digits")
}

test "every f64 survives format_f64_shortest then parse_f64" {
    let state: u64 = 0x9E37_79B9_7F4A_7C15
    for _i in 0..20000usize {
        state = state ^ (state << 13)
        state = state ^ (state >> 7)
        state = state ^ (state << 17)
        const v = f64_from_bits(state)
        if v != v {
            continue
        }
        const back = reread(v)
        assert_eq(f64_bits(back), state, "bit-exact round trip")
    }
}
