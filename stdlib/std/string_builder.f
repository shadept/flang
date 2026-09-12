// Mutable string builder for efficient string construction. Uses a growable byte buffer backed by
// the allocator pattern. Designed to support future string interpolation.

import std.allocator
import std.conv
import std.encoding.utf8
// Re-exported: `append` is this builder's front door onto `format`, so its users can call either
// without a second import.
pub import std.format
import std.io.writer
import std.mem
import std.option
import std.result
import std.string
import std.test

pub type StringBuilder = struct {
    owned ptr: &u8
    len: usize
    cap: usize
    allocator: &Allocator?
}

// Return the current contents as a String.
// The returned String points into the builder's buffer and is only valid while the builder is alive
// and not modified.
pub fn as_view(self: &StringBuilder) String {
    return .{ ptr = self.ptr, len = self.len }
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
    return move sb
}

// Create a new empty StringBuilder with the given initial capacity.
#deprecated("use string_builder(capacity)")
pub fn string_builder_with_capacity(capacity: usize) StringBuilder {
    return string_builder(capacity, null)
}

// Create a new empty StringBuilder with default capacity.
#deprecated("use string_builder(allocator=allocator)")
pub fn string_builder_with_allocator(allocator: &Allocator) StringBuilder {
    return string_builder(0, Some(allocator))
}

// Create a new empty StringBuilder with the given initial capacity.
#deprecated("use string_builder(capacity, allocator)")
pub fn string_builder_with_capacity_and_allocator(capacity: usize,
    allocator: &Allocator?) StringBuilder {
    return string_builder(capacity, allocator)
}

// Free the backing storage. The builder should not be used after this.
pub fn deinit(self: &StringBuilder) {
    if (self.cap > 0) {
        self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.cap))
    }
    self.ptr = 0usize as &u8
    self.len = 0
    self.cap = 0
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &StringBuilder, allocator: &Allocator) {
    self.deinit()
}

// Ensure the builder has room for at least `additional` more bytes.
fn reserve(self: &StringBuilder, additional: usize) {
    const required = self.len + additional
    if (self.cap >= required) {
        return
    }

    let new_cap = if (self.cap == 0) { SB_DEFAULT_CAPACITY } else { self.cap * 2 }
    if (new_cap < required) {
        new_cap = required
    }

    const resized = self.allocator.or_global()
        .realloc(slice_from_raw_parts(self.ptr, self.cap), align_of(u8), new_cap)
    if (resized.is_none()) {
        panic("StringBuilder.reserve: realloc failed")
    }

    self.ptr = resized.unwrap().ptr
    self.cap = new_cap
}

pub fn ensure_capacity(self: &StringBuilder, capacity: usize) {
    if capacity <= self.cap {
        return
    }
    self.reserve(capacity - self.len)
}

// Shrink the builder's logical length, discarding any trailing bytes. `new_len` is clamped to the
// current length, so this never grows. Backing storage is retained for reuse.
pub fn truncate(self: &StringBuilder, new_len: usize) {
    if new_len < self.len {
        self.len = new_len
    }
}

// Slice over the unused tail of the backing buffer - bytes from `sb.len` to `sb.cap`. Use with
// `commit(n)` to fill the buffer in place (e.g. from a syscall) without going through `append`.
pub fn unwritten_buf(self: &StringBuilder) u8[] {
    return slice_from_raw_parts(self.ptr + self.len, self.cap - self.len)
}

// Extend the logical length by `n` bytes, claiming bytes already written into the tail of the
// buffer (typically via `unwritten_buf()`). Panics if `n` exceeds the unwritten capacity.
pub fn commit(self: &StringBuilder, n: usize) {
    if self.len + n > self.cap {
        panic("StringBuilder.commit: n exceeds unwritten capacity")
    }
    self.len = self.len + n
}

// Transfer ownership of the current buffer as a null-terminated OwnedString. No allocation, no
// copy: the builder's buffer becomes the OwnedString's buffer and the builder is reset to empty
// (cap=0) so a subsequent deinit() is a no-op. Enables the `let sb = string_builder(); defer
// sb.deinit(); ... sb.to_string()` pattern - defer fires on panic before to_string, otherwise
// transfers cleanly.
pub fn to_string(self: &StringBuilder) OwnedString {
    // Ensure room for the null terminator. StringBuilder grows in powers of two, so cap > len is
    // the common case and reserve is a no-op.
    if (self.cap == self.len) {
        self.reserve(1)
    }

    const term = self.ptr + self.len
    term.* = 0

    const result = OwnedString { ptr = self.ptr, len = self.len, allocator = self.allocator }

    self.ptr = 0usize as &u8
    self.len = 0
    self.cap = 0
    return move result
}

// Return a copy of the current contents as a null-terminated OwnedString. Allocates from the given
// allocator.
pub fn to_string(self: &StringBuilder, allocator: &Allocator) OwnedString {
    const buf = allocator.alloc(self.len + 1, align_of(u8))
        .expect("StringBuilder.to_string: allocation failed")
    if (self.len > 0) {
        memcpy(buf.ptr, self.ptr, self.len)
    }
    // Null-terminate for C FFI compatibility
    const term = buf.ptr + self.len
    term.* = 0
    const result = OwnedString { ptr = buf.ptr, len = self.len, allocator = Some(allocator) }
    self.ptr = 0usize as &u8
    self.len = 0
    return move result
}

// Reset the builder to empty without freeing its buffer.
pub fn clear(self: &StringBuilder) {
    self.len = 0
}

// =============================================================================
// Base Append
// =============================================================================

// Append a single byte to the builder.
pub fn append_byte(self: &StringBuilder, value: u8) {
    self.reserve(1)
    const dest = self.ptr + self.len
    dest.* = value
    self.len = self.len + 1
}

// Append a byte slice to the builder.
pub fn append_bytes(self: &StringBuilder, data: u8[]) {
    if (data.len == 0) {
        return
    }
    self.reserve(data.len)
    const dest = self.ptr + self.len
    memcpy(dest, data.ptr, data.len)
    self.len = self.len + data.len
}

// =============================================================================
// format
// =============================================================================

pub fn format(self: &StringBuilder, w: Writer, spec: String) {
    self.as_view().format(w, spec)
}

// =============================================================================
// Append
// =============================================================================

// Consumes `s`: the bytes are copied in and the buffer freed, so a temporary - an interpolation, a
// `to_string()` result - passes straight in without leaking. Append `x.as_view()` to keep `x`.
pub fn append(self: &StringBuilder, s: OwnedString) {
    s.format(self.writer(), "")
    s.deinit()
}

// Consumes `s`, as the unspecced overload does.
pub fn append(self: &StringBuilder, s: OwnedString, spec: String) {
    s.format(self.writer(), spec)
    s.deinit()
}

pub fn append(self: &StringBuilder, val: $T) {
    self.append(val, "")
}

pub fn append(self: &StringBuilder, val: $T, spec: String) {
    val.format(self.writer(), spec)
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
pub fn append_replaced(self: &StringBuilder, s: String, from: String, to: String) {
    if from.len == 0 or s.len == 0 {
        self.append(s)
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
            self.append(s[start..i])
            self.append(to)
            i = i + from.len
            start = i
            continue
        }
        i = i + 1
    }
    self.append(s[start..s.len])
}

// Append `parts` joined by `sep`.
//   append_joined(sb, ["a", "b", "c"], ", ") -> "a, b, c"
pub fn append_joined(self: &StringBuilder, parts: String[], sep: String) {
    for i in 0..parts.len {
        if i > 0 {
            self.append(sep)
        }
        self.append(parts[i])
    }
}

// Append `s` repeated `n` times.
pub fn append_repeated(self: &StringBuilder, s: String, n: usize) {
    if s.len == 0 or n == 0 {
        return
    }
    self.reserve(s.len * n)
    for _i in 0..n {
        self.append(s)
    }
}

// Append the bytes of `s` in reverse order. Note: byte-reversal of multi-byte UTF-8 sequences
// produces invalid UTF-8 - use this only for ASCII content or when reversing arbitrary bytes is the
// intent.
pub fn append_reversed(self: &StringBuilder, s: String) {
    if s.len == 0 {
        return
    }
    self.reserve(s.len)
    let i: usize = s.len
    while i > 0 {
        i = i - 1
        self.append_byte(s[i])
    }
}

// Append `s` padded to at least `width` characters using `fill`. `align` is one of '<'
// (left-justify, pad on right), '>' (right-justify, pad on left), or '^' (center). When `s` is
// already at least `width` bytes wide, it is appended unchanged. Width is measured in bytes,
// matching the format-spec behavior for primitives.
pub fn append_padded(self: &StringBuilder, s: String, width: usize, align: char, fill: char) {
    if s.len >= width {
        self.append(s)
        return
    }
    const pad = width - s.len
    if align == '<' {
        self.append(s)
        for _i in 0..pad { self.append(fill) }
    } else if align == '^' {
        const left = pad / 2
        const right = pad - left
        for _i in 0..left { self.append(fill) }
        self.append(s)
        for _i in 0..right { self.append(fill) }
    } else {
        // Default / '>' - right-justify.
        for _i in 0..pad { self.append(fill) }
        self.append(s)
    }
}

// Append `s` with ASCII upper-case letters converted to lower-case. Non-ASCII bytes are copied
// through unchanged.
pub fn append_lower_ascii(self: &StringBuilder, s: String) {
    self.reserve(s.len)
    for b in s.bytes() {
        if b >= 'A' and b <= 'Z' {
            self.append_byte(b + 32)
        } else {
            self.append_byte(b)
        }
    }
}

pub fn append_upper_ascii(self: &StringBuilder, s: String) {
    self.reserve(s.len)
    for b in s.bytes() {
        if b >= 'a' and b <= 'z' {
            self.append_byte(b - 32)
        } else {
            self.append_byte(b)
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

pub fn buffered_writer(self: &StringBuilder) BufferedWriter {
    let empty: u8[]
    return buffered_writer(self.writer(), empty)
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
    sb.append(&inner, "<4")
    assert_true(sb.as_view() == "  abcd  ", "both pad; the owned temporary is freed by append")
}
