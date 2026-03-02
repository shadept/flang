// Mutable string builder for efficient string construction.
// Uses a growable byte buffer backed by the allocator pattern.
// Designed to support future string interpolation.

import std.io.writer
import std.allocator
import std.string
import std.conv
import std.test

pub type StringBuilder = struct {
    ptr: &u8
    len: usize
    cap: usize
    allocator: &Allocator?
}

// Return the current contents as a String.
// The returned String points into the builder's buffer and is only
// valid while the builder is alive and not modified.
pub fn as_view(sb: &StringBuilder) String {
    return .{ ptr = sb.ptr, len = sb.len }
}

#string_reader(StringBuilder)

const SB_DEFAULT_CAPACITY: usize = 16

// Create a new empty StringBuilder with the given initial capacity.
pub fn string_builder(capacity: usize = 0, allocator: &Allocator? = null) StringBuilder {
    let sb: StringBuilder
    sb.allocator = allocator.or_global()
    if (capacity > 0) {
        sb.reserve(capacity)
    }
    return sb
}

// Create a new empty StringBuilder with the given initial capacity.
#deprecated("use string_builder(capacity)")
pub fn string_builder_with_capacity(capacity: usize) StringBuilder {
    return string_builder(capacity, null)
}

// Create a new empty StringBuilder with default capacity.
#deprecated("use string_builder(allocator=allocator)")
pub fn string_builder_with_allocator(allocator: &Allocator) StringBuilder {
    return string_builder(0, allocator)
}

// Create a new empty StringBuilder with the given initial capacity.
#deprecated("use string_builder(capacity, allocator)")
pub fn string_builder_with_capacity_and_allocator(capacity: usize, allocator: &Allocator?) StringBuilder {
    return string_builder(capacity, allocator)
}

// Free the backing storage. The builder should not be used after this.
pub fn deinit(sb: &StringBuilder) {
    if (sb.cap > 0) {
        sb.allocator.or_global().dealloc(slice_from_raw_parts(sb.ptr, sb.cap))
    }
    let zero: usize = 0
    sb.ptr = zero as &u8
    sb.len = 0
    sb.cap = 0
}

// Ensure the builder has room for at least `additional` more bytes.
fn reserve(sb: &StringBuilder, additional: usize) {
    const required = sb.len + additional
    if (sb.cap >= required) {
        return
    }

    let new_cap = if (sb.cap == 0) { SB_DEFAULT_CAPACITY } else { sb.cap * 2 }
    if (new_cap < required) {
        new_cap = required
    }

    const resized = sb.allocator.or_global()
        .realloc(slice_from_raw_parts(sb.ptr, sb.cap), new_cap)
    if (resized.is_none()) {
        panic("StringBuilder.reserve: realloc failed")
    }

    sb.ptr = resized.value.ptr
    sb.cap = new_cap
}

pub fn ensure_capacity(sb: &StringBuilder, capacity: usize) {
    sb.reserve(capacity - sb.cap)
}

// Return a copy of the current contents as a null-terminated OwnedString.
// Allocates from the builder's own allocator.
pub fn to_string(sb: &StringBuilder) OwnedString {
    return sb.to_string(sb.allocator.or_global())
}

// Return a copy of the current contents as a null-terminated OwnedString.
// Allocates from the given allocator.
pub fn to_string(sb: &StringBuilder, allocator: &Allocator) OwnedString {
    const buf = allocator.alloc(sb.len + 1, align_of(u8))
        .expect("StringBuilder.to_string: allocation failed")
    if (sb.len > 0) {
        memcpy(buf.ptr, sb.ptr, sb.len)
    }
    // Null-terminate for C FFI compatibility
    const term = buf.ptr + sb.len
    term.* = 0
    const result = OwnedString { ptr = buf.ptr, len = sb.len, allocator }
    sb.ptr = 0usize as &u8
    sb.len = 0
    return result
}

// Reset the builder to empty without freeing its buffer.
pub fn clear(sb: &StringBuilder) {
    sb.len = 0
}

// =============================================================================
// Base Append
// =============================================================================

// Append a single byte to the builder.
pub fn append_byte(sb: &StringBuilder, value: u8) {
    sb.reserve(1)
    const dest = sb.ptr + sb.len
    dest.* = value
    sb.len = sb.len + 1
}

// Append a byte slice to the builder.
pub fn append_bytes(sb: &StringBuilder, data: u8[]) {
    if (data.len == 0) {
        return
    }
    sb.reserve(data.len)
    const dest = sb.ptr + sb.len
    memcpy(dest, data.ptr, data.len)
    sb.len = sb.len + data.len
}

pub fn append(sb: &StringBuilder, value: char) {
    const buf = [0u8; 4]
    const len = encode_char(value, buf)
    append_bytes(sb, buf[0..len])
}

// =============================================================================
// Internal Format Helpers
// =============================================================================

type FormatSpec = struct {
    base: u64
    uppercase: bool
}

fn parse_int_spec(spec: String) FormatSpec {
    if (spec.len == 0) {
        return FormatSpec { base = 10, uppercase = false }
    }
    const c = spec[0]
    if (c == b'X') {
        return FormatSpec { base = 16, uppercase = true }
    }
    if (c == b'x') {
        return FormatSpec { base = 16, uppercase = false }
    }
    if (c == b'b') {
        return FormatSpec { base = 2, uppercase = false }
    }
    if (c == b'o') {
        return FormatSpec { base = 8, uppercase = false }
    }
    return FormatSpec { base = 10, uppercase = false }
}

fn append_unsigned_with_base(sb: &StringBuilder, value: u64, base: u64, uppercase: bool) {
    let buf = [0u8; 64]
    const len = format_u64(value, buf, base as u8).unwrap()
    if uppercase {
        let i = 0usize
        loop {
            if i >= len { break }
            if buf[i] >= b'a' and buf[i] <= b'f' {
                buf[i] = buf[i] - (b'a' - b'A')
            }
            i = i + 1
        }
    }
    sb.append_bytes(buf[0..len])
}

fn append_unsigned_impl(sb: &StringBuilder, value: u64, spec: String) {
    const fmt = parse_int_spec(spec)
    append_unsigned_with_base(sb, value, fmt.base, fmt.uppercase)
}

fn mask_for_bits(bits: u64) u64 {
    if bits >= 64 { return 0xFFFF_FFFF_FFFF_FFFF }
    if bits == 32 { return 0xFFFF_FFFF }
    if bits == 16 { return 0xFFFF }
    if bits == 8 { return 0xFF }
    return 0xFFFF_FFFF_FFFF_FFFF
}

fn append_signed_impl(sb: &StringBuilder, value: i64, spec: String, bits: u64) {
    const fmt = parse_int_spec(spec)

    // For non-decimal formats, mask to original type width and show as unsigned
    // NOTE: requires bitwise AND operator to work correctly
    if fmt.base != 10 {
        const masked = (value as u64) & mask_for_bits(bits)
        append_unsigned_with_base(sb, masked, fmt.base, fmt.uppercase)
        return
    }

    // Decimal format: use format_int from std.conv
    let buf = [0; 21]
    const len = format_i64(value, buf).unwrap()
    sb.append_bytes(buf[0..len])
}

type FloatFormatSpec = struct {
    precision: usize   // decimal digits (default 6)
    has_precision: bool // whether user specified precision
    width: usize       // minimum total width (0 = no padding)
    pad_zero: bool     // pad with '0' instead of ' '
}

fn parse_float_spec(spec: String) FloatFormatSpec {
    let result = FloatFormatSpec {
        precision = 6, has_precision = false,
        width = 0, pad_zero = false
    }
    if spec.len == 0 { return result }

    let pos = 0usize

    // Leading '0' means zero-pad
    if spec[pos] == b'0' and pos + 1 < spec.len {
        result.pad_zero = true
        pos = pos + 1
    }

    // Parse width digits before '.'
    let width: usize = 0
    loop {
        if pos >= spec.len { break }
        if spec[pos] < b'0' or spec[pos] > b'9' { break }
        width = width * 10 + (spec[pos] - b'0') as usize
        pos = pos + 1
    }
    result.width = width

    // '.' followed by precision digits
    if pos < spec.len and spec[pos] == b'.' {
        pos = pos + 1
        let prec: usize = 0
        loop {
            if pos >= spec.len { break }
            if spec[pos] < b'0' or spec[pos] > b'9' { break }
            prec = prec * 10 + (spec[pos] - b'0') as usize
            pos = pos + 1
        }
        result.precision = prec
        result.has_precision = true
    }

    return result
}

fn append_float_impl(sb: &StringBuilder, val: f64, spec: String) {
    const fmt = parse_float_spec(spec)

    // Format into a temp buffer: sign + digits + '.' + frac digits
    let tmp = [0u8; 80]
    let len = 0usize

    let abs_val = val
    let negative = false
    if val < 0.0 {
        negative = true
        abs_val = 0.0 - val
    }

    // Round: add 0.5 * 10^-precision so truncation produces correct rounding
    let round = 0.5
    let r = 0usize
    loop {
        if r >= fmt.precision { break }
        round = round / 10.0
        r = r + 1
    }
    abs_val = abs_val + round

    // Integer part into a small buffer
    let int_part: u64 = abs_val as u64
    let int_buf = [0u8; 21]
    const int_len = format_u64(int_part, int_buf).unwrap()

    // Fractional digits
    let frac = abs_val - (int_part as f64)
    let frac_buf = [0u8; 20]
    let frac_len = 0usize
    let i = 0usize
    loop {
        if i >= fmt.precision { break }
        frac = frac * 10.0
        let digit: u64 = frac as u64
        frac_buf[frac_len] = (48u64 + digit) as u8
        frac_len = frac_len + 1
        frac = frac - (digit as f64)
        i = i + 1
    }

    // Trim trailing zeros only when no explicit precision was given
    if fmt.has_precision == false {
        loop {
            if frac_len == 0 { break }
            if frac_buf[frac_len - 1] != b'0' { break }
            frac_len = frac_len - 1
        }
    }

    // Assemble into tmp: ['-'] int_digits ['.' frac_digits]
    if negative {
        tmp[len] = b'-'
        len = len + 1
    }
    let j = 0usize
    loop {
        if j >= int_len { break }
        tmp[len] = int_buf[j]
        len = len + 1
        j = j + 1
    }
    if frac_len > 0 {
        tmp[len] = b'.'
        len = len + 1
        j = 0
        loop {
            if j >= frac_len { break }
            tmp[len] = frac_buf[j]
            len = len + 1
            j = j + 1
        }
    }

    // Apply width padding
    if fmt.width > len {
        const pad_count = fmt.width - len
        const pad_char: u8 = if fmt.pad_zero { b'0' } else { b' ' }
        if fmt.pad_zero and negative {
            // Zero-pad after sign: "-003.14"
            sb.append_byte(b'-')
            let k = 0usize
            loop {
                if k >= pad_count { break }
                sb.append_byte(b'0')
                k = k + 1
            }
            sb.append_bytes(tmp[1..len])
        } else {
            let k = 0usize
            loop {
                if k >= pad_count { break }
                sb.append_byte(pad_char)
                k = k + 1
            }
            sb.append_bytes(tmp[0..len])
        }
    } else {
        sb.append_bytes(tmp[0..len])
    }
}

// =============================================================================
// Unsigned Integer Append
// =============================================================================

pub fn append(sb: &StringBuilder, val: u8) {
    append_unsigned_impl(sb, val as u64, "")
}

pub fn append(sb: &StringBuilder, val: u8, spec: String) {
    append_unsigned_impl(sb, val as u64, spec)
}

pub fn append(sb: &StringBuilder, val: u16) {
    append_unsigned_impl(sb, val as u64, "")
}

pub fn append(sb: &StringBuilder, val: u16, spec: String) {
    append_unsigned_impl(sb, val as u64, spec)
}

pub fn append(sb: &StringBuilder, val: u32) {
    append_unsigned_impl(sb, val as u64, "")
}

pub fn append(sb: &StringBuilder, val: u32, spec: String) {
    append_unsigned_impl(sb, val as u64, spec)
}

pub fn append(sb: &StringBuilder, val: u64) {
    append_unsigned_impl(sb, val, "")
}

pub fn append(sb: &StringBuilder, val: u64, spec: String) {
    append_unsigned_impl(sb, val, spec)
}

pub fn append(sb: &StringBuilder, val: usize) {
    append_unsigned_impl(sb, val as u64, "")
}

pub fn append(sb: &StringBuilder, val: usize, spec: String) {
    append_unsigned_impl(sb, val as u64, spec)
}

// =============================================================================
// Signed Integer Append
// =============================================================================

pub fn append(sb: &StringBuilder, val: i8) {
    append_signed_impl(sb, val as i64, "", 8)
}

pub fn append(sb: &StringBuilder, val: i8, spec: String) {
    append_signed_impl(sb, val as i64, spec, 8)
}

pub fn append(sb: &StringBuilder, val: i16) {
    append_signed_impl(sb, val as i64, "", 16)
}

pub fn append(sb: &StringBuilder, val: i16, spec: String) {
    append_signed_impl(sb, val as i64, spec, 16)
}

pub fn append(sb: &StringBuilder, val: i32) {
    append_signed_impl(sb, val as i64, "", 32)
}

pub fn append(sb: &StringBuilder, val: i32, spec: String) {
    append_signed_impl(sb, val as i64, spec, 32)
}

pub fn append(sb: &StringBuilder, val: i64) {
    append_signed_impl(sb, val, "", 64)
}

pub fn append(sb: &StringBuilder, val: i64, spec: String) {
    append_signed_impl(sb, val, spec, 64)
}

pub fn append(sb: &StringBuilder, val: isize) {
    append_signed_impl(sb, val as i64, "", 64)
}

pub fn append(sb: &StringBuilder, val: isize, spec: String) {
    append_signed_impl(sb, val as i64, spec, 64)
}

// =============================================================================
// Floating Point Append
// =============================================================================

pub fn append(sb: &StringBuilder, val: f32) {
    append_float_impl(sb, val as f64, "")
}

pub fn append(sb: &StringBuilder, val: f32, spec: String) {
    append_float_impl(sb, val as f64, spec)
}

pub fn append(sb: &StringBuilder, val: f64) {
    append_float_impl(sb, val, "")
}

pub fn append(sb: &StringBuilder, val: f64, spec: String) {
    append_float_impl(sb, val, spec)
}

// =============================================================================
// Bool Append
// =============================================================================

pub fn append(sb: &StringBuilder, val: bool) {
    if (val) {
        sb.append("true")
    } else {
        sb.append("false")
    }
}

pub fn append(sb: &StringBuilder, val: bool, spec: String) {
    sb.append(val)
}

// =============================================================================
// Generic Append (for user-defined types with format)
// =============================================================================

// Append a String to the builder.
pub fn append(sb: &StringBuilder, s: String) {
    sb.append_bytes(slice_from_raw_parts(s.ptr, s.len))
}

pub fn append(sb: &StringBuilder, s: OwnedString) {
    sb.append(s.as_view())
}

pub fn append(sb: &StringBuilder, s: StringBuilder) {
    sb.append(s.as_view())
}

pub fn append(sb: &StringBuilder, val: $T) {
    sb.append(val, "")
}

pub fn append(sb: &StringBuilder, val: $T, spec: String) {
    val.format(sb, spec)
}

// =============================================================================
// StringWriter
// =============================================================================

fn write(self: &StringBuilder, data: u8[]) usize {
    self.append_bytes(data)
    return data.len
}

#implement(StringBuilder, Writer)

pub fn buffered_writer(sb: &StringBuilder) BufferedWriter {
    let empty: u8[]
    return buffered_writer(sb.writer(), empty)
}

// =============================================================================
// Tests
// =============================================================================

fn expect_view(sb: &StringBuilder, expected: String, msg: String) {
    const view = sb.as_view()
    assert_true(view.len == expected.len, msg)
    for i in 0..view.len {
        assert_true(view[i] == expected[i], msg)
    }
}

test "append integers" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(0i32)
    expect_view(&sb, "0", "zero")
    sb.clear()

    sb.append(42i32)
    expect_view(&sb, "42", "positive i32")
    sb.clear()

    sb.append(-123i32)
    expect_view(&sb, "-123", "negative i32")
    sb.clear()

    sb.append(255u8)
    expect_view(&sb, "255", "u8 max")
    sb.clear()

    sb.append(65535u16)
    expect_view(&sb, "65535", "u16 max")
    sb.clear()

    sb.append(4294967295u32)
    expect_view(&sb, "4294967295", "u32 max")
    sb.clear()

    sb.append(9223372036854775807i64)
    expect_view(&sb, "9223372036854775807", "i64 max")
    sb.clear()

    sb.append(-9223372036854775807i64)
    expect_view(&sb, "-9223372036854775807", "large negative i64")
}

test "append bool and string" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(true)
    expect_view(&sb, "true", "bool true")
    sb.clear()

    sb.append(false)
    expect_view(&sb, "false", "bool false")
    sb.clear()

    sb.append("hello ")
    sb.append("world")
    expect_view(&sb, "hello world", "string append")
    sb.clear()

    sb.append("abc")
    sb.append(123i32)
    expect_view(&sb, "abc123", "mixed string and int")
}

test "append all int sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append("u8: ")
    sb.append(0u8)
    sb.append(" ")
    sb.append(127u8)
    sb.append(" ")
    sb.append(255u8)
    expect_view(&sb, "u8: 0 127 255", "u8 sizes")
    sb.clear()

    sb.append("i8: ")
    sb.append(0i8)
    sb.append(" ")
    sb.append(127i8)
    sb.append(" ")
    sb.append(-128i8)
    expect_view(&sb, "i8: 0 127 -128", "i8 sizes")
    sb.clear()

    sb.append("u16: ")
    sb.append(0u16)
    sb.append(" ")
    sb.append(32767u16)
    sb.append(" ")
    sb.append(65535u16)
    expect_view(&sb, "u16: 0 32767 65535", "u16 sizes")
    sb.clear()

    sb.append("i16: ")
    sb.append(0i16)
    sb.append(" ")
    sb.append(32767i16)
    sb.append(" ")
    sb.append(-32768i16)
    expect_view(&sb, "i16: 0 32767 -32768", "i16 sizes")
    sb.clear()

    sb.append("u32: ")
    sb.append(0u32)
    sb.append(" ")
    sb.append(2147483647u32)
    sb.append(" ")
    sb.append(4294967295u32)
    expect_view(&sb, "u32: 0 2147483647 4294967295", "u32 sizes")
    sb.clear()

    sb.append("i32: ")
    sb.append(0i32)
    sb.append(" ")
    sb.append(2147483647i32)
    sb.append(" ")
    sb.append(-2147483648i32)
    expect_view(&sb, "i32: 0 2147483647 -2147483648", "i32 sizes")
}

test "append format hex" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(255u8, "x")
    expect_view(&sb, "ff", "u8 hex lower")
    sb.clear()

    sb.append(255u8, "X")
    expect_view(&sb, "FF", "u8 hex upper")
    sb.clear()

    sb.append(3735928559u32, "x")
    expect_view(&sb, "deadbeef", "u32 hex")
    sb.clear()

    sb.append(3735928559u32, "X")
    expect_view(&sb, "DEADBEEF", "u32 hex upper")
    sb.clear()

    sb.append(0u32, "x")
    expect_view(&sb, "0", "zero hex")
    sb.clear()

    sb.append(9223372036854775807i64, "x")
    expect_view(&sb, "7fffffffffffffff", "i64 max hex")
}

test "append format octal binary" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(255u8, "o")
    expect_view(&sb, "377", "u8 octal")
    sb.clear()

    sb.append(255u8, "b")
    expect_view(&sb, "11111111", "u8 binary")
    sb.clear()

    sb.append(42u8, "o")
    expect_view(&sb, "52", "42 octal")
    sb.clear()

    sb.append(42u8, "b")
    expect_view(&sb, "101010", "42 binary")
    sb.clear()

    sb.append(0u8, "o")
    expect_view(&sb, "0", "zero octal")
    sb.clear()

    sb.append(0u8, "b")
    expect_view(&sb, "0", "zero binary")
}

test "append signed hex" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(-1i32, "x")
    expect_view(&sb, "ffffffff", "i32 -1 hex")
    sb.clear()

    sb.append(-123i64, "x")
    expect_view(&sb, "ffffffffffffff85", "i64 -123 hex")
    sb.clear()

    sb.append(42i32, "x")
    expect_view(&sb, "2a", "i32 42 hex")
}

test "append signed hex all sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(-1i8, "x")
    expect_view(&sb, "ff", "i8 -1 hex")
    sb.clear()

    sb.append(-128i8, "x")
    expect_view(&sb, "80", "i8 -128 hex")
    sb.clear()

    sb.append(-1i16, "x")
    expect_view(&sb, "ffff", "i16 -1 hex")
    sb.clear()

    sb.append(-32768i16, "x")
    expect_view(&sb, "8000", "i16 min hex")
    sb.clear()

    sb.append(-1i32, "x")
    expect_view(&sb, "ffffffff", "i32 -1 hex")
    sb.clear()

    sb.append(-2147483648i32, "x")
    expect_view(&sb, "80000000", "i32 min hex")
    sb.clear()

    sb.append(-1i64, "x")
    expect_view(&sb, "ffffffffffffffff", "i64 -1 hex")
    sb.clear()

    sb.append(-9223372036854775808i64, "x")
    expect_view(&sb, "8000000000000000", "i64 min hex")
}

test "append unsigned hex all sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(255u8, "x")
    expect_view(&sb, "ff", "u8 max hex")
    sb.clear()

    sb.append(65535u16, "x")
    expect_view(&sb, "ffff", "u16 max hex")
    sb.clear()

    sb.append(4294967295u32, "x")
    expect_view(&sb, "ffffffff", "u32 max hex")
    sb.clear()

    sb.append(18446744073709551615u64, "x")
    expect_view(&sb, "ffffffffffffffff", "u64 max hex")
    sb.clear()

    sb.append(128u8, "x")
    expect_view(&sb, "80", "u8 high bit")
    sb.clear()

    sb.append(32768u16, "x")
    expect_view(&sb, "8000", "u16 high bit")
    sb.clear()

    sb.append(2147483648u32, "x")
    expect_view(&sb, "80000000", "u32 high bit")
}

test "append floats" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(3.14f64)
    expect_view(&sb, "3.14", "f64 3.14")
    sb.clear()

    sb.append(0.0f64)
    expect_view(&sb, "0", "f64 zero")
    sb.clear()

    sb.append(-1.5f64)
    expect_view(&sb, "-1.5", "f64 negative")
    sb.clear()

    sb.append(42.0f64)
    expect_view(&sb, "42", "f64 integer value")
    sb.clear()

    sb.append(1.0f32)
    expect_view(&sb, "1", "f32 one")
    sb.clear()

    sb.append(0.125f64)
    expect_view(&sb, "0.125", "f64 0.125")
}

test "append floats with precision" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(3.14f64, ".2")
    expect_view(&sb, "3.14", "f64 .2 precision")
    sb.clear()

    sb.append(3.14f64, ".4")
    expect_view(&sb, "3.1400", "f64 .4 precision")
    sb.clear()

    sb.append(1.0f64, ".0")
    expect_view(&sb, "1", "f64 .0 precision")
    sb.clear()

    sb.append(1.0f64, ".3")
    expect_view(&sb, "1.000", "f64 .3 precision")
    sb.clear()
}

test "append floats with width" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(3.14f64, "8.2")
    expect_view(&sb, "    3.14", "f64 width 8")
    sb.clear()

    sb.append(3.14f64, "08.2")
    expect_view(&sb, "00003.14", "f64 zero-pad width 8")
    sb.clear()

    sb.append(-3.14f64, "08.2")
    expect_view(&sb, "-0003.14", "f64 neg zero-pad")
    sb.clear()
}

test "append binary octal all sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(255u8, "b")
    expect_view(&sb, "11111111", "u8 max binary")
    sb.clear()

    sb.append(255u8, "o")
    expect_view(&sb, "377", "u8 max octal")
    sb.clear()

    sb.append(65535u16, "b")
    expect_view(&sb, "1111111111111111", "u16 max binary")
    sb.clear()

    sb.append(65535u16, "o")
    expect_view(&sb, "177777", "u16 max octal")
    sb.clear()

    sb.append(-1i8, "b")
    expect_view(&sb, "11111111", "i8 -1 binary")
    sb.clear()

    sb.append(-1i8, "o")
    expect_view(&sb, "377", "i8 -1 octal")
    sb.clear()

    sb.append(-1i16, "b")
    expect_view(&sb, "1111111111111111", "i16 -1 binary")
    sb.clear()

    sb.append(-1i16, "o")
    expect_view(&sb, "177777", "i16 -1 octal")
}
