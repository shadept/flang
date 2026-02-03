// Mutable string builder for efficient string construction.
// Uses a growable byte buffer backed by the allocator pattern.
// Designed to support future string interpolation.

import std.io.buffer
import std.allocator

pub struct StringBuilder {
    ptr: &u8
    len: usize
    cap: usize
    allocator: &Allocator?
}

fn get_allocator(self: StringBuilder) &Allocator {
    return self.allocator ?? &global_allocator
}

// Create a new empty StringBuilder with default capacity.
pub fn string_builder(allocator: &Allocator?) StringBuilder {
    return string_builder_with_capacity(16, allocator)
}

// Create a new empty StringBuilder with the given initial capacity.
pub fn string_builder_with_capacity(capacity: usize, allocator: &Allocator?) StringBuilder {
    const alloc = allocator ?? &global_allocator
    const buf = alloc.alloc(capacity, 1).expect("string_builder_with_capacity: allocation failed")
    return StringBuilder {
        ptr = buf.ptr,
        len = 0,
        cap = capacity,
        allocator = allocator,
    }
}

// Ensure the builder has room for at least `additional` more bytes.
fn reserve(sb: &StringBuilder, additional: usize) {
    const required = sb.len + additional
    if (sb.cap >= required) {
        return
    }

    let new_cap = if (sb.cap == 0) 16 else sb.cap * 2
    if (new_cap < required) {
        new_cap = required
    }

    const alloc = sb.get_allocator()
    const old_slice = slice_from_raw_parts(sb.ptr, sb.cap)
    const resized = alloc.realloc(old_slice, new_cap)
    if (resized.is_none()) {
        panic("StringBuilder.reserve: realloc failed")
    }
    sb.ptr = resized.value.ptr
    sb.cap = new_cap
}

// Append a single raw byte to the builder (not numeric representation).
pub fn append_byte(sb: &StringBuilder, value: u8) {
    sb.reserve(1)
    const dest = sb.ptr + sb.len
    dest.* = value
    sb.len = sb.len + 1
}

// =============================================================================
// Primitive Type Append Functions
// =============================================================================
// Each primitive type has two append functions:
//   append(&StringBuilder, T)           - default decimal representation
//   append(&StringBuilder, T, String)   - with format spec (C-style)
//
// Format spec supports:
//   ""  or "d" - decimal (default)
//   "x"        - lowercase hexadecimal
//   "X"        - uppercase hexadecimal
//   "o"        - octal
//   "b"        - binary
// =============================================================================

// Helper: convert a digit (0-35) to ASCII character
fn digit_to_char(digit: u8, uppercase: bool) u8 {
    if (digit < 10) {
        return 48 + digit  // '0' = 48
    }
    if (uppercase) {
        return 55 + digit  // 'A' - 10 = 55
    }
    return 87 + digit      // 'a' - 10 = 87
}

// Helper: get base from format spec
fn spec_to_base(spec: String) u8 {
    if (spec.len == 0) {
        return 10
    }
    const c = spec.ptr.*
    if (c == 100) { return 10 }  // 'd'
    if (c == 105) { return 10 }  // 'i'
    if (c == 120) { return 16 }  // 'x'
    if (c == 88)  { return 16 }  // 'X'
    if (c == 111) { return 8 }   // 'o'
    if (c == 98)  { return 2 }   // 'b'
    return 10  // default to decimal
}

// Helper: check if spec is uppercase hex
fn spec_is_uppercase(spec: String) bool {
    if (spec.len == 0) {
        return false
    }
    return spec.ptr.* == 88  // 'X'
}

// -----------------------------------------------------------------------------
// bool
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: bool) {
    if (value) {
        sb.append("true")
    } else {
        sb.append("false")
    }
}

pub fn append(sb: &StringBuilder, value: bool, spec: String) {
    // bool ignores spec for now
    sb.append(value)
}

// -----------------------------------------------------------------------------
// u8 - numeric representation
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: u8) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: u8, spec: String) {
    const base = spec_to_base(spec)
    const uppercase = spec_is_uppercase(spec)

    // Max digits for u8: 8 (binary) + possible prefix
    let buf: [u8; 10] = [0 as u8; 10]
    let idx: usize = 10
    let val = value

    if (val == 0) {
        idx = idx - 1
        buf[idx] = 48  // '0'
    } else {
        while (val > 0) {
            idx = idx - 1
            const digit = (val % base) as u8
            buf[idx] = digit_to_char(digit, uppercase)
            val = val / base
        }
    }

    const slice = slice_from_raw_parts(&buf[idx], 10 - idx)
    sb.append_bytes(slice)
}

// -----------------------------------------------------------------------------
// i8
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: i8) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: i8, spec: String) {
    if (value < 0) {
        sb.append_byte(45)  // '-'
        // Safe: -128 as i8, negated is 128 which fits in u8
        const abs_val = (-(value as i32)) as u8
        sb.append(abs_val, spec)
    } else {
        sb.append(value as u8, spec)
    }
}

// -----------------------------------------------------------------------------
// u16
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: u16) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: u16, spec: String) {
    const base = spec_to_base(spec) as u16
    const uppercase = spec_is_uppercase(spec)

    // Max digits for u16: 16 (binary)
    let buf: [u8; 20] = [0 as u8; 20]
    let idx: usize = 20
    let val = value

    if (val == 0) {
        idx = idx - 1
        buf[idx] = 48  // '0'
    } else {
        while (val > 0) {
            idx = idx - 1
            const digit = (val % base) as u8
            buf[idx] = digit_to_char(digit, uppercase)
            val = val / base
        }
    }

    const slice = slice_from_raw_parts(&buf[idx], 20 - idx)
    sb.append_bytes(slice)
}

// -----------------------------------------------------------------------------
// i16
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: i16) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: i16, spec: String) {
    if (value < 0) {
        sb.append_byte(45)  // '-'
        const abs_val = (-(value as i32)) as u16
        sb.append(abs_val, spec)
    } else {
        sb.append(value as u16, spec)
    }
}

// -----------------------------------------------------------------------------
// u32
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: u32) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: u32, spec: String) {
    const base = spec_to_base(spec) as u32
    const uppercase = spec_is_uppercase(spec)

    // Max digits for u32: 32 (binary)
    let buf: [u8; 40] = [0 as u8; 40]
    let idx: usize = 40
    let val = value

    if (val == 0) {
        idx = idx - 1
        buf[idx] = 48  // '0'
    } else {
        while (val > 0) {
            idx = idx - 1
            const digit = (val % base) as u8
            buf[idx] = digit_to_char(digit, uppercase)
            val = val / base
        }
    }

    const slice = slice_from_raw_parts(&buf[idx], 40 - idx)
    sb.append_bytes(slice)
}

// -----------------------------------------------------------------------------
// i32
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: i32) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: i32, spec: String) {
    if (value < 0) {
        sb.append_byte(45)  // '-'
        const abs_val = (-(value as i64)) as u32
        sb.append(abs_val, spec)
    } else {
        sb.append(value as u32, spec)
    }
}

// -----------------------------------------------------------------------------
// u64
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: u64) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: u64, spec: String) {
    const base = spec_to_base(spec) as u64
    const uppercase = spec_is_uppercase(spec)

    // Max digits for u64: 64 (binary)
    let buf: [u8; 70] = [0 as u8; 70]
    let idx: usize = 70
    let val = value

    if (val == 0) {
        idx = idx - 1
        buf[idx] = 48  // '0'
    } else {
        while (val > 0) {
            idx = idx - 1
            const digit = (val % base) as u8
            buf[idx] = digit_to_char(digit, uppercase)
            val = val / base
        }
    }

    const slice = slice_from_raw_parts(&buf[idx], 70 - idx)
    sb.append_bytes(slice)
}

// -----------------------------------------------------------------------------
// i64
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: i64) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: i64, spec: String) {
    if (value < 0) {
        sb.append_byte(45)  // '-'
        // Handle i64 min specially to avoid overflow
        if (value == -9223372036854775808) {
            // i64::MIN cannot be negated, handle specially
            sb.append("9223372036854775808")
        } else {
            const abs_val = (-value) as u64
            sb.append(abs_val, spec)
        }
    } else {
        sb.append(value as u64, spec)
    }
}

// -----------------------------------------------------------------------------
// usize
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: usize) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: usize, spec: String) {
    // usize is same size as u64 on 64-bit platforms
    sb.append(value as u64, spec)
}

// -----------------------------------------------------------------------------
// isize
// -----------------------------------------------------------------------------
pub fn append(sb: &StringBuilder, value: isize) {
    sb.append(value, "")
}

pub fn append(sb: &StringBuilder, value: isize, spec: String) {
    // isize is same size as i64 on 64-bit platforms
    sb.append(value as i64, spec)
}

pub fn append(sb: &StringBuilder, s: OwnedString) {
    sb.append(s.as_view())
}

// Append a String to the builder.
pub fn append(sb: &StringBuilder, s: String) {
    if (s.len == 0) {
        return
    }
    sb.reserve(s.len)
    const dest = sb.ptr + sb.len
    memcpy(dest, s.ptr, s.len)
    sb.len = sb.len + s.len
}

// Append a String to the builder.
pub fn append(sb: &StringBuilder, val: $T) {
    sb.append(val, "")
}

// Append a String to the builder.
pub fn append(sb: &StringBuilder, val: $T, spec: String) {
    val.format(sb, spec)
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

// Return the current contents as a String.
// The returned String points into the builder's buffer and is only
// valid while the builder is alive and not modified.
pub fn as_view(sb: &StringBuilder) String {
    return .{ ptr = sb.ptr, len = sb.len }
}

// Return a copy of the current contents as a null-terminated String.
// Allocates from the builder's own allocator.
pub fn to_string(sb: &StringBuilder) OwnedString {
    return sb.to_string(sb.get_allocator())
}

// Return a copy of the current contents as a null-terminated String.
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

// Free the backing storage. The builder should not be used after this.
pub fn deinit(sb: &StringBuilder) {
    if (sb.cap > 0) {
        const alloc = sb.get_allocator()
        const old_slice = slice_from_raw_parts(sb.ptr, sb.cap)
        alloc.free(old_slice)
    }
    let zero: usize = 0
    sb.ptr = zero as &u8
    sb.len = 0
    sb.cap = 0
}

// =============================================================================
// StringWriter
// =============================================================================

struct StringWriter {
    sb: &StringBuilder
}

fn sb_write(ctx: &u8, buf: u8[]) usize {
    const writer = ctx as &StringWriter
    writer.sb.append_bytes(buf)
    return buf.len
}

pub fn writer(sb: &StringBuilder) BufferedWriter {
    const wfn = WriteFn { ctx = sb as &u8, write = sb_write }
    const storage = [0 as u8; 0] as u8[]
    return buffered_writer(wfn, storage)
}
