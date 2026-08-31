// `format` - a value's text, written to a sink.
//
// `fn format(self: T, w: Writer, spec: String)` is printf's job with the printing taken out: a
// value, a spec, and somewhere to put the bytes. The sink is any `Writer` - a socket, a file, a
// `StringBuilder` - so the same impl serves every destination, and building a string is one use of
// it rather than the shape of it.
//
// What comes out is the value's TEXT. `42i32.format(w, "")` writes the two bytes `4` and `2`, not
// the four bytes of the integer. Serialization of a value's representation is a different job with
// a different protocol (`std.encoding.codec`).
//
// Text reaches the sink as UTF-8, matching `String`'s in-memory encoding. A destination that needs
// other bytes on the wire transcodes in its own `Writer`; nothing above the sink knows or cares.
//
// Every type in FLang should have a `format` so generic code can call `value.format(w, spec)`
// without knowing what it was handed, the same contract `core.deinit` states for cleanup. A type
// declares itself formattable by declaring the function, and it belongs in the file that declares
// the type. This module holds the two sets with nowhere else to live - the primitives, which have
// no declaring file, and `String`, declared in `core` where the sink cannot be named - plus the
// spec parsing and padding every impl shares.
//
// A `format` body writes literals with `w.write_str(...)` and delegates values to their own
// `format`.

import std.io.writer
import std.string_builder
import std.allocator
import std.string
import std.conv
import std.encoding.utf8
import std.mem
import std.result
import std.option
import std.test

// =============================================================================
// The primitives
// =============================================================================

pub fn format(self: u8, w: Writer, spec: String) {
    write_unsigned(w, self as u64, spec)
}

pub fn format(self: u16, w: Writer, spec: String) {
    write_unsigned(w, self as u64, spec)
}

pub fn format(self: u32, w: Writer, spec: String) {
    write_unsigned(w, self as u64, spec)
}

pub fn format(self: u64, w: Writer, spec: String) {
    write_unsigned(w, self, spec)
}

pub fn format(self: usize, w: Writer, spec: String) {
    write_unsigned(w, self as u64, spec)
}

pub fn format(self: i8, w: Writer, spec: String) {
    write_signed(w, self as i64, spec, 8)
}

pub fn format(self: i16, w: Writer, spec: String) {
    write_signed(w, self as i64, spec, 16)
}

pub fn format(self: i32, w: Writer, spec: String) {
    write_signed(w, self as i64, spec, 32)
}

pub fn format(self: i64, w: Writer, spec: String) {
    write_signed(w, self, spec, 64)
}

pub fn format(self: isize, w: Writer, spec: String) {
    write_signed(w, self as i64, spec, 64)
}

pub fn format(self: f32, w: Writer, spec: String) {
    write_float(w, self as f64, spec)
}

pub fn format(self: f64, w: Writer, spec: String) {
    write_float(w, self, spec)
}

pub fn format(self: bool, w: Writer, spec: String) {
    const text = if self { "true" } else { "false" }
    text.format(w, spec)
}

pub fn format(self: String, w: Writer, spec: String) {
    write_text(w, slice_from_raw_parts(self.ptr, self.len), spec)
}

// Width counts the encoded bytes of the character, so a multi-byte char pads narrower than it
// looks.
pub fn format(self: char, w: Writer, spec: String) {
    const buf = [0u8; 4]
    const len = encode_char(self, buf)
    write_text(w, buf[0..len], spec)
}

// =============================================================================
// Spec parsing and padding
// =============================================================================

type FormatSpec = struct {
    base: u64
    uppercase: bool
    width: usize
    fill: u8 // pad character (default space)
    align: u8 // '<' left, '>' right, '^' center (default '>')
    pad_zero: bool // '0' flag: zero-pad after sign
}

fn is_align_char(c: u8) bool {
    return c == '<' or c == '>' or c == '^'
}

fn is_base_char(c: u8) bool {
    return c == 'x' or c == 'X' or c == 'b' or c == 'o'
}

// Parse format spec: [fill][align][0][width][type] Examples: "8", ">8", "<8x", "^10", "-<8", "08x",
// "08X"
fn parse_int_spec(spec: String) FormatSpec {
    let result = FormatSpec {
        base = 10,
        uppercase = false,
        width = 0,
        fill = ' ',
        align = '>',
        pad_zero = false,
    }
    if spec.len == 0 {
        return result
    }

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

// A writer reports how many bytes it took; formatting has nowhere to put that number.
fn put(w: Writer, content: u8[]) {
    let _n = w.write(content)
}

// Write `pad_count` copies of `fill_char`. Batched: a sink call per byte would dominate the cost of
// formatting a padded value.
fn write_fill(w: Writer, fill_char: u8, pad_count: usize) {
    let chunk = [0u8; 32]
    for i in 0..32usize {
        chunk[i] = fill_char
    }
    let left = pad_count
    while left > 0 {
        const n = if left < 32 { left } else { 32usize }
        put(w, chunk[0..n])
        left = left - n
    }
}

// Emit `content` widened to `width` with `fill`, placed per `align`: '<' left, '^' centered,
// anything else right. Content at least as wide as `width` is emitted unchanged.
fn write_padded(w: Writer, content: u8[], width: usize, fill: u8, align: u8) {
    if width <= content.len {
        put(w, content)
        return
    }
    const pad_count = width - content.len

    if align == '<' {
        put(w, content)
        write_fill(w, fill, pad_count)
    } else if align == '^' {
        const left = pad_count / 2
        write_fill(w, fill, left)
        put(w, content)
        write_fill(w, fill, pad_count - left)
    } else {
        write_fill(w, fill, pad_count)
        put(w, content)
    }
}

// Emit content (in tmp[0..len]) with alignment/padding per fmt. Zero-padding a right-aligned number
// keeps the sign in front of the zeros: "-007".
fn write_int_padded(w: Writer, tmp: u8[], len: usize, fmt: &FormatSpec) {
    if fmt.pad_zero and fmt.align == '>' and fmt.width > len and len > 0 and tmp[0] == '-' {
        put(w, ['-'])
        write_fill(w, '0', fmt.width - len)
        put(w, tmp[1..len])
        return
    }
    write_padded(w, tmp[0..len], fmt.width, fmt.fill, fmt.align)
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

fn write_unsigned(w: Writer, value: u64, spec: String) {
    const fmt = parse_int_spec(spec)
    let tmp = [0u8; 64]
    const len = format_unsigned_into(tmp, value, fmt.base, fmt.uppercase)
    write_int_padded(w, tmp, len, &fmt)
}

fn mask_for_bits(bits: u64) u64 {
    if bits >= 64 {
        return 0xFFFF_FFFF_FFFF_FFFF
    }
    if bits == 32 {
        return 0xFFFF_FFFF
    }
    if bits == 16 {
        return 0xFFFF
    }
    if bits == 8 {
        return 0xFF
    }
    return 0xFFFF_FFFF_FFFF_FFFF
}

fn write_signed(w: Writer, value: i64, spec: String, bits: u64) {
    const fmt = parse_int_spec(spec)

    // For non-decimal formats, mask to original type width and show as unsigned
    if fmt.base != 10 {
        let tmp = [0u8; 64]
        const masked = (value as u64) & mask_for_bits(bits)
        const len = format_unsigned_into(tmp, masked, fmt.base, fmt.uppercase)
        write_int_padded(w, tmp, len, &fmt)
        return
    }

    // Decimal format
    let tmp = [0u8; 21]
    const len = format_i64(value, tmp).unwrap()
    write_int_padded(w, tmp, len, &fmt)
}

type FloatFormatSpec = struct {
    precision: usize // decimal digits (default 6)
    has_precision: bool // whether user specified precision
    width: usize // minimum total width (0 = no padding)
    pad_zero: bool // pad with '0' instead of ' '
    fill: u8 // pad character (default space)
    align: u8 // '<' left, '>' right, '^' center (default '>')
}

// Parse float format spec: [fill][align][0][width][.precision]
fn parse_float_spec(spec: String) FloatFormatSpec {
    let result = FloatFormatSpec {
        precision = 6,
        has_precision = false,
        width = 0,
        pad_zero = false,
        fill = ' ',
        align = '>',
    }
    if spec.len == 0 {
        return result
    }

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

// Emit content (in tmp[0..len]) with alignment/padding per fmt. Mirrors `write_int_padded` - the
// sign-aware zero-pad branch handles "-003.14".
fn write_float_padded(w: Writer, tmp: u8[], len: usize, fmt: &FloatFormatSpec) {
    if fmt.pad_zero and fmt.align == '>' and fmt.width > len and len > 0 and tmp[0] == '-' {
        put(w, ['-'])
        write_fill(w, '0', fmt.width - len)
        put(w, tmp[1..len])
        return
    }
    write_padded(w, tmp[0..len], fmt.width, fmt.fill, fmt.align)
}

// Float spec grammar: [fill][align][0][width][.precision][type], where `type` is `e` / `E`
// (scientific, `format_f64_exp`) or `a` (exact C99 hex-float, `format_f64_hex` - the round-trip
// representation; width and alignment apply, precision is inherent to the bits). No type char is
// plain fixed-point (`format_f64`).
fn write_float(w: Writer, val: f64, spec: String) {
    let kind: u8 = 'f'
    let body = spec
    if spec.len > 0 {
        const last = spec[spec.len - 1]
        if last == 'e' or last == 'E' or last == 'a' {
            kind = last
            body = spec[0..spec.len - 1]
        }
    }
    const fmt = parse_float_spec(body)
    let tmp = [0u8; 64]
    let len: usize = 0
    if kind == 'a' {
        len = format_f64_hex(val, tmp).unwrap()
    } else if kind == 'f' {
        len = format_f64(val, tmp, fmt.precision, fmt.has_precision == false).unwrap()
    } else {
        len = format_f64_exp(val, tmp, fmt.precision, kind == 'E').unwrap()
    }
    write_float_padded(w, tmp, len, &fmt)
}

// Text spec grammar: [fill][align][0][width]. Width is a minimum measured in bytes; text at least
// that wide is written whole. The trailing base char of the integer grammar has no meaning here and
// is ignored.
fn write_text(w: Writer, content: u8[], spec: String) {
    const fmt = parse_int_spec(spec)
    write_padded(w, content, fmt.width, fmt.fill, fmt.align)
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

test "format is defined for every builtin" {
    let sb = string_builder(64)
    defer sb.deinit()
    const w = sb.writer()

    7i32.format(w, "03")
    2.5f64.format(w, ".1")
    true.format(w, ">5")
    "x".format(w, "<3")
    255u8.format(w, "X")

    assert_true(sb.as_view() == "0072.5 truex  FF", "a value writes its own text to the sink")
}

test "append integers" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    0i32.format(w, "")
    expect_view(&sb, "0", "zero")
    sb.clear()

    42i32.format(w, "")
    expect_view(&sb, "42", "positive i32")
    sb.clear()

    format(-123i32, w, "")
    expect_view(&sb, "-123", "negative i32")
    sb.clear()

    255u8.format(w, "")
    expect_view(&sb, "255", "u8 max")
    sb.clear()

    65535u16.format(w, "")
    expect_view(&sb, "65535", "u16 max")
    sb.clear()

    4294967295u32.format(w, "")
    expect_view(&sb, "4294967295", "u32 max")
    sb.clear()

    9223372036854775807i64.format(w, "")
    expect_view(&sb, "9223372036854775807", "i64 max")
    sb.clear()

    format(-9223372036854775807i64, w, "")
    expect_view(&sb, "-9223372036854775807", "large negative i64")
}

test "append bool and string" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    true.format(w, "")
    expect_view(&sb, "true", "bool true")
    sb.clear()

    false.format(w, "")
    expect_view(&sb, "false", "bool false")
    sb.clear()

    "hello ".format(w, "")
    "world".format(w, "")
    expect_view(&sb, "hello world", "string append")
    sb.clear()

    "abc".format(w, "")
    123i32.format(w, "")
    expect_view(&sb, "abc123", "mixed string and int")
}

test "append all int sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    "u8: ".format(w, "")
    0u8.format(w, "")
    " ".format(w, "")
    127u8.format(w, "")
    " ".format(w, "")
    255u8.format(w, "")
    expect_view(&sb, "u8: 0 127 255", "u8 sizes")
    sb.clear()

    "i8: ".format(w, "")
    0i8.format(w, "")
    " ".format(w, "")
    127i8.format(w, "")
    " ".format(w, "")
    format(-128i8, w, "")
    expect_view(&sb, "i8: 0 127 -128", "i8 sizes")
    sb.clear()

    "u16: ".format(w, "")
    0u16.format(w, "")
    " ".format(w, "")
    32767u16.format(w, "")
    " ".format(w, "")
    65535u16.format(w, "")
    expect_view(&sb, "u16: 0 32767 65535", "u16 sizes")
    sb.clear()

    "i16: ".format(w, "")
    0i16.format(w, "")
    " ".format(w, "")
    32767i16.format(w, "")
    " ".format(w, "")
    format(-32768i16, w, "")
    expect_view(&sb, "i16: 0 32767 -32768", "i16 sizes")
    sb.clear()

    "u32: ".format(w, "")
    0u32.format(w, "")
    " ".format(w, "")
    2147483647u32.format(w, "")
    " ".format(w, "")
    4294967295u32.format(w, "")
    expect_view(&sb, "u32: 0 2147483647 4294967295", "u32 sizes")
    sb.clear()

    "i32: ".format(w, "")
    0i32.format(w, "")
    " ".format(w, "")
    2147483647i32.format(w, "")
    " ".format(w, "")
    format(-2147483648i32, w, "")
    expect_view(&sb, "i32: 0 2147483647 -2147483648", "i32 sizes")
}

test "append format hex" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    255u8.format(w, "x")
    expect_view(&sb, "ff", "u8 hex lower")
    sb.clear()

    255u8.format(w, "X")
    expect_view(&sb, "FF", "u8 hex upper")
    sb.clear()

    3735928559u32.format(w, "x")
    expect_view(&sb, "deadbeef", "u32 hex")
    sb.clear()

    3735928559u32.format(w, "X")
    expect_view(&sb, "DEADBEEF", "u32 hex upper")
    sb.clear()

    0u32.format(w, "x")
    expect_view(&sb, "0", "zero hex")
    sb.clear()

    9223372036854775807i64.format(w, "x")
    expect_view(&sb, "7fffffffffffffff", "i64 max hex")
}

test "append format octal binary" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    255u8.format(w, "o")
    expect_view(&sb, "377", "u8 octal")
    sb.clear()

    255u8.format(w, "b")
    expect_view(&sb, "11111111", "u8 binary")
    sb.clear()

    42u8.format(w, "o")
    expect_view(&sb, "52", "42 octal")
    sb.clear()

    42u8.format(w, "b")
    expect_view(&sb, "101010", "42 binary")
    sb.clear()

    0u8.format(w, "o")
    expect_view(&sb, "0", "zero octal")
    sb.clear()

    0u8.format(w, "b")
    expect_view(&sb, "0", "zero binary")
}

test "append signed hex" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    format(-1i32, w, "x")
    expect_view(&sb, "ffffffff", "i32 -1 hex")
    sb.clear()

    format(-123i64, w, "x")
    expect_view(&sb, "ffffffffffffff85", "i64 -123 hex")
    sb.clear()

    42i32.format(w, "x")
    expect_view(&sb, "2a", "i32 42 hex")
}

test "append signed hex all sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    format(-1i8, w, "x")
    expect_view(&sb, "ff", "i8 -1 hex")
    sb.clear()

    format(-128i8, w, "x")
    expect_view(&sb, "80", "i8 -128 hex")
    sb.clear()

    format(-1i16, w, "x")
    expect_view(&sb, "ffff", "i16 -1 hex")
    sb.clear()

    format(-32768i16, w, "x")
    expect_view(&sb, "8000", "i16 min hex")
    sb.clear()

    format(-1i32, w, "x")
    expect_view(&sb, "ffffffff", "i32 -1 hex")
    sb.clear()

    format(-2147483648i32, w, "x")
    expect_view(&sb, "80000000", "i32 min hex")
    sb.clear()

    format(-1i64, w, "x")
    expect_view(&sb, "ffffffffffffffff", "i64 -1 hex")
    sb.clear()

    format(-9223372036854775808i64, w, "x")
    expect_view(&sb, "8000000000000000", "i64 min hex")
}

test "append unsigned hex all sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    255u8.format(w, "x")
    expect_view(&sb, "ff", "u8 max hex")
    sb.clear()

    65535u16.format(w, "x")
    expect_view(&sb, "ffff", "u16 max hex")
    sb.clear()

    4294967295u32.format(w, "x")
    expect_view(&sb, "ffffffff", "u32 max hex")
    sb.clear()

    18446744073709551615u64.format(w, "x")
    expect_view(&sb, "ffffffffffffffff", "u64 max hex")
    sb.clear()

    128u8.format(w, "x")
    expect_view(&sb, "80", "u8 high bit")
    sb.clear()

    32768u16.format(w, "x")
    expect_view(&sb, "8000", "u16 high bit")
    sb.clear()

    2147483648u32.format(w, "x")
    expect_view(&sb, "80000000", "u32 high bit")
}

test "append floats" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    3.14f64.format(w, "")
    expect_view(&sb, "3.14", "f64 3.14")
    sb.clear()

    0.0f64.format(w, "")
    expect_view(&sb, "0", "f64 zero")
    sb.clear()

    format(-1.5f64, w, "")
    expect_view(&sb, "-1.5", "f64 negative")
    sb.clear()

    42.0f64.format(w, "")
    expect_view(&sb, "42", "f64 integer value")
    sb.clear()

    1.0f32.format(w, "")
    expect_view(&sb, "1", "f32 one")
    sb.clear()

    0.125f64.format(w, "")
    expect_view(&sb, "0.125", "f64 0.125")
}

test "append floats with precision" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    3.14f64.format(w, ".2")
    expect_view(&sb, "3.14", "f64 .2 precision")
    sb.clear()

    3.14f64.format(w, ".4")
    expect_view(&sb, "3.1400", "f64 .4 precision")
    sb.clear()

    1.0f64.format(w, ".0")
    expect_view(&sb, "1", "f64 .0 precision")
    sb.clear()

    1.0f64.format(w, ".3")
    expect_view(&sb, "1.000", "f64 .3 precision")
    sb.clear()
}

test "append floats scientific" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    1.5f64.format(w, "e")
    expect_view(&sb, "1.500000e+00", "default six digits")
    sb.clear()

    format(-2.5e-3f64, w, ".3e")
    expect_view(&sb, "-2.500e-03", "precision and negative exponent")
    sb.clear()

    1.0e300f64.format(w, ".2e")
    expect_view(&sb, "1.00e+300", "three-digit exponent")
    sb.clear()

    9.9999f64.format(w, ".3E")
    expect_view(&sb, "1.000E+01", "rounding carries into the exponent; E uppercases")
    sb.clear()

    0.0f64.format(w, ".1e")
    expect_view(&sb, "0.0e+00", "zero")
    sb.clear()
}

test "append floats exact hex" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    1.5f64.format(w, "a")
    expect_view(&sb, "0x1.8p+0", "1.5 is 0x1.8p+0")
    sb.clear()

    3.141592653589793f64.format(w, "a")
    expect_view(&sb, "0x1.921fb54442d18p+1", "every mantissa bit survives")
    sb.clear()

    0.0f64.format(w, "a")
    expect_view(&sb, "0x0p+0", "zero")
    sb.clear()

    format(-0.5f64, w, "a")
    expect_view(&sb, "-0x1p-1", "sign and whole-power values omit the point")
    sb.clear()

    5e-324f64.format(w, "a")
    expect_view(&sb, "0x0.0000000000001p-1022", "the smallest denormal round-trips")
    sb.clear()

    1.5f64.format(w, "12a")
    expect_view(&sb, "    0x1.8p+0", "width applies around the exact form")
    sb.clear()
}

test "append floats with width" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    3.14f64.format(w, "8.2")
    expect_view(&sb, "    3.14", "f64 width 8")
    sb.clear()

    3.14f64.format(w, "08.2")
    expect_view(&sb, "00003.14", "f64 zero-pad width 8")
    sb.clear()

    format(-3.14f64, w, "08.2")
    expect_view(&sb, "-0003.14", "f64 neg zero-pad")
    sb.clear()
}

test "append binary octal all sizes" {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    255u8.format(w, "b")
    expect_view(&sb, "11111111", "u8 max binary")
    sb.clear()

    255u8.format(w, "o")
    expect_view(&sb, "377", "u8 max octal")
    sb.clear()

    65535u16.format(w, "b")
    expect_view(&sb, "1111111111111111", "u16 max binary")
    sb.clear()

    65535u16.format(w, "o")
    expect_view(&sb, "177777", "u16 max octal")
    sb.clear()

    format(-1i8, w, "b")
    expect_view(&sb, "11111111", "i8 -1 binary")
    sb.clear()

    format(-1i8, w, "o")
    expect_view(&sb, "377", "i8 -1 octal")
    sb.clear()

    format(-1i16, w, "b")
    expect_view(&sb, "1111111111111111", "i16 -1 binary")
    sb.clear()

    format(-1i16, w, "o")
    expect_view(&sb, "177777", "i16 -1 octal")
}

test "int width right align" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    42usize.format(w, "8")
    expect_view(&sb, "      42", "usize width 8")
    sb.clear()

    42i32.format(w, "8")
    expect_view(&sb, "      42", "i32 width 8")
    sb.clear()

    format(-42i32, w, "8")
    expect_view(&sb, "     -42", "i32 neg width 8")
    sb.clear()

    7u8.format(w, "4")
    expect_view(&sb, "   7", "u8 width 4")
    sb.clear()

    12345usize.format(w, "4")
    expect_view(&sb, "12345", "usize exceeds width")
    sb.clear()
}

test "int width left align" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    42usize.format(w, "<8")
    expect_view(&sb, "42      ", "usize left 8")
    sb.clear()

    format(-42i32, w, "<8")
    expect_view(&sb, "-42     ", "i32 neg left 8")
    sb.clear()
}

test "int width center align" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    42usize.format(w, "^8")
    expect_view(&sb, "   42   ", "usize center 8")
    sb.clear()

    7u8.format(w, "^5")
    expect_view(&sb, "  7  ", "u8 center 5")
    sb.clear()

    42usize.format(w, "^7")
    expect_view(&sb, "  42   ", "usize center 7 odd pad")
    sb.clear()
}

test "int zero pad" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    42usize.format(w, "08")
    expect_view(&sb, "00000042", "usize zero-pad 8")
    sb.clear()

    format(-42i32, w, "08")
    expect_view(&sb, "-0000042", "i32 neg zero-pad 8")
    sb.clear()

    255u8.format(w, "08x")
    expect_view(&sb, "000000ff", "u8 zero-pad hex")
    sb.clear()

    255u8.format(w, "08X")
    expect_view(&sb, "000000FF", "u8 zero-pad HEX")
    sb.clear()
}

test "int custom fill" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    42usize.format(w, "-<8")
    expect_view(&sb, "42------", "dash left-fill")
    sb.clear()

    42usize.format(w, ".>8")
    expect_view(&sb, "......42", "dot right-fill")
    sb.clear()

    42usize.format(w, "*^8")
    expect_view(&sb, "***42***", "star center-fill")
    sb.clear()
}

test "int width with base" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    255u8.format(w, ">8x")
    expect_view(&sb, "      ff", "hex right width 8")
    sb.clear()

    255u8.format(w, "<8x")
    expect_view(&sb, "ff      ", "hex left width 8")
    sb.clear()

    15u8.format(w, "^6x")
    expect_view(&sb, "  f   ", "hex center width 6")
    sb.clear()
}

test "float alignment" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    3.14f64.format(w, "<10.2")
    expect_view(&sb, "3.14      ", "f64 left 10")
    sb.clear()

    3.14f64.format(w, "^10.2")
    expect_view(&sb, "   3.14   ", "f64 center 10")
    sb.clear()

    3.14f64.format(w, ">10.2")
    expect_view(&sb, "      3.14", "f64 right 10")
    sb.clear()

    3.14f64.format(w, "-<10.2")
    expect_view(&sb, "3.14------", "f64 dash left 10")
    sb.clear()
}

test "append text with a spec" {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()
    let sb = string_builder(allocator = Some(&alloc))
    const w = sb.writer()

    "hi".format(w, ">6")
    expect_view(&sb, "    hi", "right-align is the default")
    sb.clear()

    "hi".format(w, "<6")
    expect_view(&sb, "hi    ", "left-align")
    sb.clear()

    "hi".format(w, ".^6")
    expect_view(&sb, "..hi..", "centered with an explicit fill")
    sb.clear()

    "hello".format(w, "3")
    expect_view(&sb, "hello", "width is a minimum, not a maximum")
    sb.clear()

    "hi".format(w, "")
    expect_view(&sb, "hi", "an empty spec pads nothing")
    sb.clear()

    'x'.format(w, ">3")
    expect_view(&sb, "  x", "a char pads by its encoded byte count")
}
