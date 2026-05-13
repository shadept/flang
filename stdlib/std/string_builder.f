// Mutable string builder for efficient string construction.
// Uses a growable byte buffer backed by the allocator pattern.
// Designed to support future string interpolation.

import std.io.writer
import std.allocator
import std.string
import std.conv
import std.encoding.utf8
import std.mem
import std.option
import std.result
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
        sb.allocator.or_global().free(slice_from_raw_parts(sb.ptr, sb.cap))
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

    sb.ptr = resized.unwrap().ptr
    sb.cap = new_cap
}

pub fn ensure_capacity(sb: &StringBuilder, capacity: usize) {
    if capacity <= sb.cap {
        return
    }
    sb.reserve(capacity - sb.len)
}

// Shrink the builder's logical length, discarding any trailing bytes.
// `new_len` is clamped to the current length, so this never grows. Backing
// storage is retained for reuse.
pub fn truncate(sb: &StringBuilder, new_len: usize) {
    if new_len < sb.len {
        sb.len = new_len
    }
}

// Slice over the unused tail of the backing buffer — bytes from `sb.len`
// to `sb.cap`. Use with `commit(n)` to fill the buffer in place (e.g.
// from a syscall) without going through `append`.
pub fn unwritten_buf(sb: &StringBuilder) u8[] {
    return slice_from_raw_parts(sb.ptr + sb.len, sb.cap - sb.len)
}

// Extend the logical length by `n` bytes, claiming bytes already written
// into the tail of the buffer (typically via `unwritten_buf()`). Panics
// if `n` exceeds the unwritten capacity.
pub fn commit(sb: &StringBuilder, n: usize) {
    if sb.len + n > sb.cap {
        panic("StringBuilder.commit: n exceeds unwritten capacity")
    }
    sb.len = sb.len + n
}

// Transfer ownership of the current buffer as a null-terminated OwnedString.
// No allocation, no copy: the builder's buffer becomes the OwnedString's buffer
// and the builder is reset to empty (cap=0) so a subsequent deinit() is a no-op.
// Enables the `let sb = string_builder(); defer sb.deinit(); ... sb.to_string()`
// pattern — defer fires on panic before to_string, otherwise transfers cleanly.
pub fn to_string(sb: &StringBuilder) OwnedString {
    const alloc = sb.allocator.or_global()

    // Ensure room for the null terminator. StringBuilder grows in powers of two,
    // so cap > len is the common case and reserve is a no-op.
    if (sb.cap == sb.len) {
        sb.reserve(1)
    }

    const term = sb.ptr + sb.len
    term.* = 0

    const result = OwnedString { ptr = sb.ptr, len = sb.len, allocator = alloc }

    let zero: usize = 0
    sb.ptr = zero as &u8
    sb.len = 0
    sb.cap = 0
    return result
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
    width: usize
    fill: u8       // pad character (default space)
    align: u8      // '<' left, '>' right, '^' center (default '>')
    pad_zero: bool // '0' flag: zero-pad after sign
}

fn is_align_char(c: u8) bool {
    return c == '<' or c == '>' or c == '^'
}

fn is_base_char(c: u8) bool {
    return c == 'x' or c == 'X' or c == 'b' or c == 'o'
}

// Parse format spec: [fill][align][0][width][type]
// Examples: "8", ">8", "<8x", "^10", "-<8", "08x", "08X"
fn parse_int_spec(spec: String) FormatSpec {
    let result = FormatSpec {
        base = 10, uppercase = false,
        width = 0, fill = ' ', align = '>', pad_zero = false
    }
    if spec.len == 0 { return result }

    let pos = 0usize

    // Try [fill][align] or just [align]
    if pos + 1 < spec.len and is_align_char(spec[pos + 1]) {
        // fill + align: e.g. "-<", ".^"
        result.fill = spec[pos]
        result.align = spec[pos + 1]
        pos = pos + 2
    } else if pos < spec.len and is_align_char(spec[pos]) {
        // bare align: e.g. "<", ">", "^"
        result.align = spec[pos]
        pos = pos + 1
    }

    // '0' flag for zero-padding (only meaningful with right-align)
    if pos < spec.len and spec[pos] == '0' and pos + 1 < spec.len {
        result.pad_zero = true
        result.fill = '0'
        pos = pos + 1
    }

    // Parse width digits
    let width: usize = 0
    while pos < spec.len and spec[pos] >= '0' and spec[pos] <= '9' {
        width = width * 10 + (spec[pos] - '0') as usize
        pos = pos + 1
    }
    result.width = width

    // Parse base type char
    if pos < spec.len {
        const c = spec[pos]
        if c == 'X' {
            result.base = 16
            result.uppercase = true
        } else if c == 'x' {
            result.base = 16
        } else if c == 'b' {
            result.base = 2
        } else if c == 'o' {
            result.base = 8
        }
    }

    return result
}

// Write pad_count copies of fill_char into sb.
fn repeat_fill(sb: &StringBuilder, fill_char: u8, pad_count: usize) {
    for k in 0..pad_count {
        sb.append_byte(fill_char)
    }
}

// Emit content (in tmp[0..len]) with alignment/padding per fmt.
// For zero-pad with sign, sign_len is 1 if tmp starts with '-'.
fn apply_int_padding(sb: &StringBuilder, tmp: u8[], len: usize, fmt: &FormatSpec) {
    if fmt.width <= len {
        sb.append_bytes(tmp[0..len])
        return
    }
    const pad_count = fmt.width - len

    if fmt.pad_zero and fmt.align == '>' {
        // Zero-pad after sign: "-007"
        if len > 0 and tmp[0] == '-' {
            sb.append_byte('-')
            repeat_fill(sb, '0', pad_count)
            sb.append_bytes(tmp[1..len])
        } else {
            repeat_fill(sb, '0', pad_count)
            sb.append_bytes(tmp[0..len])
        }
        return
    }

    if fmt.align == '<' {
        // Left-align: content then padding
        sb.append_bytes(tmp[0..len])
        repeat_fill(sb, fmt.fill, pad_count)
    } else if fmt.align == '^' {
        // Center: split padding
        const left = pad_count / 2
        const right = pad_count - left
        repeat_fill(sb, fmt.fill, left)
        sb.append_bytes(tmp[0..len])
        repeat_fill(sb, fmt.fill, right)
    } else {
        // Right-align (default)
        repeat_fill(sb, fmt.fill, pad_count)
        sb.append_bytes(tmp[0..len])
    }
}

fn format_unsigned_into(tmp: u8[], value: u64, base: u64, uppercase: bool) usize {
    const len = format_u64(value, tmp, base as u8).unwrap()
    if uppercase {
        for i in 0..len {
            if tmp[i] >= 'a' and tmp[i] <= 'f' {
                tmp[i] = tmp[i] - ('a' - 'A')
            }
        }
    }
    return len
}

fn append_unsigned_impl(sb: &StringBuilder, value: u64, spec: String) {
    const fmt = parse_int_spec(spec)
    let tmp = [0u8; 64]
    const len = format_unsigned_into(tmp, value, fmt.base, fmt.uppercase)
    apply_int_padding(sb, tmp, len, &fmt)
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
    if fmt.base != 10 {
        let tmp = [0u8; 64]
        const masked = (value as u64) & mask_for_bits(bits)
        const len = format_unsigned_into(tmp, masked, fmt.base, fmt.uppercase)
        apply_int_padding(sb, tmp, len, &fmt)
        return
    }

    // Decimal format
    let tmp = [0u8; 21]
    const len = format_i64(value, tmp).unwrap()
    apply_int_padding(sb, tmp, len, &fmt)
}

type FloatFormatSpec = struct {
    precision: usize   // decimal digits (default 6)
    has_precision: bool // whether user specified precision
    width: usize       // minimum total width (0 = no padding)
    pad_zero: bool     // pad with '0' instead of ' '
    fill: u8           // pad character (default space)
    align: u8          // '<' left, '>' right, '^' center (default '>')
}

// Parse float format spec: [fill][align][0][width][.precision]
fn parse_float_spec(spec: String) FloatFormatSpec {
    let result = FloatFormatSpec {
        precision = 6, has_precision = false,
        width = 0, pad_zero = false,
        fill = ' ', align = '>'
    }
    if spec.len == 0 { return result }

    let pos = 0usize

    // Try [fill][align] or just [align]
    if pos + 1 < spec.len and is_align_char(spec[pos + 1]) {
        result.fill = spec[pos]
        result.align = spec[pos + 1]
        pos = pos + 2
    } else if pos < spec.len and is_align_char(spec[pos]) {
        result.align = spec[pos]
        pos = pos + 1
    }

    // '0' flag for zero-padding
    if pos < spec.len and spec[pos] == '0' and pos + 1 < spec.len {
        result.pad_zero = true
        result.fill = '0'
        pos = pos + 1
    }

    // Parse width digits before '.'
    let width: usize = 0
    while pos < spec.len and spec[pos] >= '0' and spec[pos] <= '9' {
        width = width * 10 + (spec[pos] - '0') as usize
        pos = pos + 1
    }
    result.width = width

    // '.' followed by precision digits
    if pos < spec.len and spec[pos] == '.' {
        pos = pos + 1
        let prec: usize = 0
        while pos < spec.len and spec[pos] >= '0' and spec[pos] <= '9' {
            prec = prec * 10 + (spec[pos] - '0') as usize
            pos = pos + 1
        }
        result.precision = prec
        result.has_precision = true
    }

    return result
}

// Emit content (in tmp[0..len]) with alignment/padding per fmt. Mirrors
// `apply_int_padding` — the sign-aware zero-pad branch handles "-003.14".
fn apply_float_padding(sb: &StringBuilder, tmp: u8[], len: usize, fmt: &FloatFormatSpec) {
    if fmt.width <= len {
        sb.append_bytes(tmp[0..len])
        return
    }
    const pad_count = fmt.width - len

    if fmt.pad_zero and fmt.align == '>' {
        // Zero-pad after sign: "-003.14"
        if len > 0 and tmp[0] == '-' {
            sb.append_byte('-')
            repeat_fill(sb, '0', pad_count)
            sb.append_bytes(tmp[1..len])
        } else {
            repeat_fill(sb, '0', pad_count)
            sb.append_bytes(tmp[0..len])
        }
        return
    }

    if fmt.align == '<' {
        sb.append_bytes(tmp[0..len])
        repeat_fill(sb, fmt.fill, pad_count)
    } else if fmt.align == '^' {
        const left = pad_count / 2
        const right = pad_count - left
        repeat_fill(sb, fmt.fill, left)
        sb.append_bytes(tmp[0..len])
        repeat_fill(sb, fmt.fill, right)
    } else {
        // Right-align (default)
        repeat_fill(sb, fmt.fill, pad_count)
        sb.append_bytes(tmp[0..len])
    }
}

fn append_float_impl(sb: &StringBuilder, val: f64, spec: String) {
    const fmt = parse_float_spec(spec)
    let tmp = [0u8; 64]
    const len = format_f64(val, tmp, fmt.precision, fmt.has_precision == false).unwrap()
    apply_float_padding(sb, tmp, len, &fmt)
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
// String-transforming appenders
// =============================================================================
//
// Each of these reads from `s` (and friends) and writes the transformed result
// onto `sb`. They never allocate beyond growing `sb`. Compose with `to_string()`
// when an OwnedString result is wanted:
//
//   let sb = string_builder()
//   defer sb.deinit()
//   sb.append_replaced("hello world", "world", "FLang")
//   let owned = sb.to_string()

// Append `s` with every occurrence of `from` replaced by `to`. An empty `from`
// is a no-op (just appends `s` unchanged).
pub fn append_replaced(sb: &StringBuilder, s: String, from: String, to: String) {
    if from.len == 0 or s.len == 0 {
        sb.append(s)
        return
    }
    let i: usize = 0
    let start: usize = 0
    loop {
        if i + from.len > s.len { break }
        let matched: bool = true
        for k in 0..from.len {
            if s[i + k] != from[k] { matched = false; break }
        }
        if matched {
            sb.append(s[start..i])
            sb.append(to)
            i = i + from.len
            start = i
            continue
        }
        i = i + 1
    }
    sb.append(s[start..s.len])
}

// Append `parts` joined by `sep`.
//   append_joined(sb, ["a", "b", "c"], ", ") -> "a, b, c"
pub fn append_joined(sb: &StringBuilder, parts: String[], sep: String) {
    for i in 0..parts.len {
        if i > 0 { sb.append(sep) }
        sb.append(parts[i])
    }
}

// Append `s` repeated `n` times.
pub fn append_repeated(sb: &StringBuilder, s: String, n: usize) {
    if s.len == 0 or n == 0 { return }
    sb.reserve(s.len * n)
    for _i in 0..n {
        sb.append(s)
    }
}

// Append the bytes of `s` in reverse order. Note: byte-reversal of multi-byte
// UTF-8 sequences produces invalid UTF-8 — use this only for ASCII content or
// when reversing arbitrary bytes is the intent.
pub fn append_reversed(sb: &StringBuilder, s: String) {
    if s.len == 0 { return }
    sb.reserve(s.len)
    let i: usize = s.len
    while i > 0 {
        i = i - 1
        sb.append_byte(s[i])
    }
}

// Append `s` padded to at least `width` characters using `fill`. `align` is
// one of '<' (left-justify, pad on right), '>' (right-justify, pad on left),
// or '^' (center). When `s` is already at least `width` bytes wide, it is
// appended unchanged. Width is measured in bytes, matching the format-spec
// behavior for primitives.
pub fn append_padded(sb: &StringBuilder, s: String, width: usize, align: char, fill: char) {
    if s.len >= width {
        sb.append(s)
        return
    }
    const pad = width - s.len
    if align == '<' {
        sb.append(s)
        for _i in 0..pad { sb.append(fill) }
    } else if align == '^' {
        const left = pad / 2
        const right = pad - left
        for _i in 0..left { sb.append(fill) }
        sb.append(s)
        for _i in 0..right { sb.append(fill) }
    } else {
        // Default / '>' — right-justify.
        for _i in 0..pad { sb.append(fill) }
        sb.append(s)
    }
}

// Append `s` with ASCII upper-case letters converted to lower-case. Non-ASCII
// bytes are copied through unchanged.
pub fn append_lower_ascii(sb: &StringBuilder, s: String) {
    sb.reserve(s.len)
    for i in 0..s.len {
        const b = s[i]
        if b >= 'A' and b <= 'Z' {
            sb.append_byte(b + 32)
        } else {
            sb.append_byte(b)
        }
    }
}

pub fn append_upper_ascii(sb: &StringBuilder, s: String) {
    sb.reserve(s.len)
    for i in 0..s.len {
        const b = s[i]
        if b >= 'a' and b <= 'z' {
            sb.append_byte(b - 32)
        } else {
            sb.append_byte(b)
        }
    }
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

test "int width right align" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(42usize, "8")
    expect_view(&sb, "      42", "usize width 8")
    sb.clear()

    sb.append(42i32, "8")
    expect_view(&sb, "      42", "i32 width 8")
    sb.clear()

    sb.append(-42i32, "8")
    expect_view(&sb, "     -42", "i32 neg width 8")
    sb.clear()

    sb.append(7u8, "4")
    expect_view(&sb, "   7", "u8 width 4")
    sb.clear()

    sb.append(12345usize, "4")
    expect_view(&sb, "12345", "usize exceeds width")
    sb.clear()
}

test "int width left align" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(42usize, "<8")
    expect_view(&sb, "42      ", "usize left 8")
    sb.clear()

    sb.append(-42i32, "<8")
    expect_view(&sb, "-42     ", "i32 neg left 8")
    sb.clear()
}

test "int width center align" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(42usize, "^8")
    expect_view(&sb, "   42   ", "usize center 8")
    sb.clear()

    sb.append(7u8, "^5")
    expect_view(&sb, "  7  ", "u8 center 5")
    sb.clear()

    sb.append(42usize, "^7")
    expect_view(&sb, "  42   ", "usize center 7 odd pad")
    sb.clear()
}

test "int zero pad" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(42usize, "08")
    expect_view(&sb, "00000042", "usize zero-pad 8")
    sb.clear()

    sb.append(-42i32, "08")
    expect_view(&sb, "-0000042", "i32 neg zero-pad 8")
    sb.clear()

    sb.append(255u8, "08x")
    expect_view(&sb, "000000ff", "u8 zero-pad hex")
    sb.clear()

    sb.append(255u8, "08X")
    expect_view(&sb, "000000FF", "u8 zero-pad HEX")
    sb.clear()
}

test "int custom fill" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(42usize, "-<8")
    expect_view(&sb, "42------", "dash left-fill")
    sb.clear()

    sb.append(42usize, ".>8")
    expect_view(&sb, "......42", "dot right-fill")
    sb.clear()

    sb.append(42usize, "*^8")
    expect_view(&sb, "***42***", "star center-fill")
    sb.clear()
}

test "int width with base" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(255u8, ">8x")
    expect_view(&sb, "      ff", "hex right width 8")
    sb.clear()

    sb.append(255u8, "<8x")
    expect_view(&sb, "ff      ", "hex left width 8")
    sb.clear()

    sb.append(15u8, "^6x")
    expect_view(&sb, "  f   ", "hex center width 6")
    sb.clear()
}

test "float alignment" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator=&alloc)

    sb.append(3.14f64, "<10.2")
    expect_view(&sb, "3.14      ", "f64 left 10")
    sb.clear()

    sb.append(3.14f64, "^10.2")
    expect_view(&sb, "   3.14   ", "f64 center 10")
    sb.clear()

    sb.append(3.14f64, ">10.2")
    expect_view(&sb, "      3.14", "f64 right 10")
    sb.clear()

    sb.append(3.14f64, "-<10.2")
    expect_view(&sb, "3.14------", "f64 dash left 10")
    sb.clear()
}
