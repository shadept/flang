// Mutable string builder for efficient string construction.
// Uses a growable byte buffer backed by the allocator pattern.
// Designed to support future string interpolation.

import std.io.writer
import std.allocator
import std.string
import std.conv

pub type StringBuilder = struct {
    ptr: &u8
    len: usize
    cap: usize
    allocator: &Allocator?
}

const DEFAULT_CAPACITY: usize = 16

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

    let new_cap = if (sb.cap == 0) { DEFAULT_CAPACITY } else { sb.cap * 2 }
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

// Return the current contents as a String.
// The returned String points into the builder's buffer and is only
// valid while the builder is alive and not modified.
pub fn as_view(sb: &StringBuilder) String {
    return .{ ptr = sb.ptr, len = sb.len }
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
    const len = format_uint(value, buf, base as u8).unwrap()
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
    if (fmt.base != 10) {
        const masked = (value as u64) & mask_for_bits(bits)
        append_unsigned_with_base(sb, masked, fmt.base, fmt.uppercase)
        return
    }

    // Decimal format: use format_int from std.conv
    let buf = [0u8; 21]
    const len = format_int(value, buf, 10).unwrap()
    sb.append_bytes(buf[0..len])
}

// fn append_float_impl(sb: &StringBuilder, val: f64, spec: String) {
//     if (val < 0.0) {
//         sb.append_byte(b'-')
//         append_float_impl(sb, 0.0 - val, spec)
//         return
//     }
//
//     let int_part: u64 = val as u64
//     append_unsigned_with_base(sb, int_part, 10, false)
//
//     sb.append_byte(b'.')
//
//     let frac = val - (int_part as f64)
//     let precision: usize = 6
//
//     for (i in 0..precision) {
//         frac = frac * 10.0
//         let digit: u64 = frac as u64
//         sb.append_byte((48u64 + digit) as u8)
//         frac = frac - (digit as f64)
//     }
// }

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

//pub fn append(sb: &StringBuilder, val: f32) {
//    append_float_impl(sb, val as f64, "")
//}

//pub fn append(sb: &StringBuilder, val: f32, spec: String) {
//    append_float_impl(sb, val as f64, spec)
//}

//pub fn append(sb: &StringBuilder, val: f64) {
//    append_float_impl(sb, val, "")
//}

//pub fn append(sb: &StringBuilder, val: f64, spec: String) {
//    append_float_impl(sb, val, spec)
//}

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

pub fn append(sb: &StringBuilder, s: OwnedString) {
    sb.append(s.as_view())
}

// Append a String to the builder.
pub fn append(sb: &StringBuilder, s: String) {
    sb.append_bytes(slice_from_raw_parts(s.ptr, s.len))
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

fn sb_write(ctx: &u8, buf: u8[]) usize {
    const sb = ctx as &StringBuilder
    sb.append_bytes(buf)
    return buf.len
}

pub fn writer(sb: &StringBuilder) Writer {
    const wfn = WriteFn { ctx = sb as &u8, write = sb_write }
    const storage = [0; 0]
    return writer(wfn, storage)
}
