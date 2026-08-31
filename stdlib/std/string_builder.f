// Mutable string builder for efficient string construction. Uses a growable byte buffer backed by
// the allocator pattern. Designed to support future string interpolation.

import std.io.writer
import std.allocator
import std.string
import std.conv
// Re-exported: `append` is this builder's front door onto `format`, so its users can call either
// without a second import.
pub import std.format
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
// The returned String points into the builder's buffer and is only valid while the builder is alive
// and not modified.
pub fn as_view(sb: &StringBuilder) String {
    return .{ ptr = sb.ptr, len = sb.len }
}

#string_reader(StringBuilder)

const SB_DEFAULT_CAPACITY: usize = 16

// Create a new empty StringBuilder with the given initial capacity.
pub fn string_builder(capacity: usize = 0, allocator: &Allocator? = null) StringBuilder {
    let sb: StringBuilder
    sb.allocator = allocator
    if (capacity > 0) {
        sb.reserve(capacity)
    }
    return sb
}

// Create a new empty StringBuilder with the given initial capacity.
#deprecated ("use string_builder(capacity)")
pub fn string_builder_with_capacity(capacity: usize) StringBuilder {
    return string_builder(capacity, null)
}

// Create a new empty StringBuilder with default capacity.
#deprecated ("use string_builder(allocator=allocator)")
pub fn string_builder_with_allocator(allocator: &Allocator) StringBuilder {
    return string_builder(0, Some(allocator))
}

// Create a new empty StringBuilder with the given initial capacity.
#deprecated ("use string_builder(capacity, allocator)")
pub fn string_builder_with_capacity_and_allocator(capacity: usize,
    allocator: &Allocator?) StringBuilder {
    return string_builder(capacity, allocator)
}

// Free the backing storage. The builder should not be used after this.
pub fn deinit(sb: &StringBuilder) {
    if (sb.cap > 0) {
        sb.allocator.or_global().free(slice_from_raw_parts(sb.ptr, sb.cap))
    }
    sb.ptr = 0usize as &u8
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
        .realloc(slice_from_raw_parts(sb.ptr, sb.cap), align_of(u8), new_cap)
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

// Shrink the builder's logical length, discarding any trailing bytes. `new_len` is clamped to the
// current length, so this never grows. Backing storage is retained for reuse.
pub fn truncate(sb: &StringBuilder, new_len: usize) {
    if new_len < sb.len {
        sb.len = new_len
    }
}

// Slice over the unused tail of the backing buffer - bytes from `sb.len` to `sb.cap`. Use with
// `commit(n)` to fill the buffer in place (e.g. from a syscall) without going through `append`.
pub fn unwritten_buf(sb: &StringBuilder) u8[] {
    return slice_from_raw_parts(sb.ptr + sb.len, sb.cap - sb.len)
}

// Extend the logical length by `n` bytes, claiming bytes already written into the tail of the
// buffer (typically via `unwritten_buf()`). Panics if `n` exceeds the unwritten capacity.
pub fn commit(sb: &StringBuilder, n: usize) {
    if sb.len + n > sb.cap {
        panic("StringBuilder.commit: n exceeds unwritten capacity")
    }
    sb.len = sb.len + n
}

// Transfer ownership of the current buffer as a null-terminated OwnedString. No allocation, no
// copy: the builder's buffer becomes the OwnedString's buffer and the builder is reset to empty
// (cap=0) so a subsequent deinit() is a no-op. Enables the `let sb = string_builder(); defer
// sb.deinit(); ... sb.to_string()` pattern - defer fires on panic before to_string, otherwise
// transfers cleanly.
pub fn to_string(sb: &StringBuilder) OwnedString {
    // Ensure room for the null terminator. StringBuilder grows in powers of two, so cap > len is
    // the common case and reserve is a no-op.
    if (sb.cap == sb.len) {
        sb.reserve(1)
    }

    const term = sb.ptr + sb.len
    term.* = 0

    const result = OwnedString { ptr = sb.ptr, len = sb.len, allocator = sb.allocator }

    sb.ptr = 0usize as &u8
    sb.len = 0
    sb.cap = 0
    return result
}

// Return a copy of the current contents as a null-terminated OwnedString. Allocates from the given
// allocator.
pub fn to_string(sb: &StringBuilder, allocator: &Allocator) OwnedString {
    const buf = allocator.alloc(sb.len + 1, align_of(u8))
        .expect("StringBuilder.to_string: allocation failed")
    if (sb.len > 0) {
        memcpy(buf.ptr, sb.ptr, sb.len)
    }
    // Null-terminate for C FFI compatibility
    const term = buf.ptr + sb.len
    term.* = 0
    const result = OwnedString { ptr = buf.ptr, len = sb.len, allocator = Some(allocator) }
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

// =============================================================================
// format
// =============================================================================

pub fn format(self: StringBuilder, w: Writer, spec: String) {
    self.as_view().format(w, spec)
}

// =============================================================================
// Append
// =============================================================================

// Consumes `s`: the bytes are copied in and the buffer freed, so a temporary - an interpolation, a
// `to_string()` result - passes straight in without leaking. Append `x.as_view()` to keep `x`.
pub fn append(sb: &StringBuilder, s: OwnedString) {
    s.format(sb.writer(), "")
    s.deinit()
}

// Consumes `s`, as the unspecced overload does.
pub fn append(sb: &StringBuilder, s: OwnedString, spec: String) {
    s.format(sb.writer(), spec)
    s.deinit()
}

pub fn append(sb: &StringBuilder, val: $T) {
    sb.append(val, "")
}

pub fn append(sb: &StringBuilder, val: $T, spec: String) {
    val.format(sb.writer(), spec)
}

// =============================================================================
// String-transforming appenders
// =============================================================================
//
// Each of these reads from `s` (and friends) and writes the transformed result onto `sb`. They
// never allocate beyond growing `sb`. Compose with `to_string()` when an OwnedString result is
// wanted:
//
//   let sb = string_builder()
//   defer sb.deinit()
//   sb.append_replaced("hello world", "world", "FLang")
//   let owned = sb.to_string()

// Append `s` with every occurrence of `from` replaced by `to`. An empty `from` is a no-op (just
// appends `s` unchanged).
pub fn append_replaced(sb: &StringBuilder, s: String, from: String, to: String) {
    if from.len == 0 or s.len == 0 {
        sb.append(s)
        return
    }
    let i: usize = 0
    let start: usize = 0
    loop {
        if i + from.len > s.len {
            break
        }
        let matched: bool = true
        for k in 0..from.len {
            if s[i + k] != from[k] {
                matched = false
                break
            }
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
        if i > 0 {
            sb.append(sep)
        }
        sb.append(parts[i])
    }
}

// Append `s` repeated `n` times.
pub fn append_repeated(sb: &StringBuilder, s: String, n: usize) {
    if s.len == 0 or n == 0 {
        return
    }
    sb.reserve(s.len * n)
    for _i in 0..n {
        sb.append(s)
    }
}

// Append the bytes of `s` in reverse order. Note: byte-reversal of multi-byte UTF-8 sequences
// produces invalid UTF-8 - use this only for ASCII content or when reversing arbitrary bytes is the
// intent.
pub fn append_reversed(sb: &StringBuilder, s: String) {
    if s.len == 0 {
        return
    }
    sb.reserve(s.len)
    let i: usize = s.len
    while i > 0 {
        i = i - 1
        sb.append_byte(s[i])
    }
}

// Append `s` padded to at least `width` characters using `fill`. `align` is one of '<'
// (left-justify, pad on right), '>' (right-justify, pad on left), or '^' (center). When `s` is
// already at least `width` bytes wide, it is appended unchanged. Width is measured in bytes,
// matching the format-spec behavior for primitives.
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
        // Default / '>' - right-justify.
        for _i in 0..pad { sb.append(fill) }
        sb.append(s)
    }
}

// Append `s` with ASCII upper-case letters converted to lower-case. Non-ASCII bytes are copied
// through unchanged.
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

test "append consumes an owned string" {
    let sb = string_builder(8)
    defer sb.deinit()
    sb.append($"a{1i32}b")
    sb.append(from_view("!"))
    assert_true(sb.as_view() == "a1b!", "the bytes land; the temporaries are freed by append")
}

test "append owned and builder with a spec" {
    let sb = string_builder(32)
    defer sb.deinit()

    let inner = string_builder(8)
    defer inner.deinit()
    inner.append("cd")

    sb.append(from_view("ab"), ">4")
    sb.append(inner, "<4")
    assert_true(sb.as_view() == "  abcd  ", "both pad; the owned temporary is freed by append")
}
