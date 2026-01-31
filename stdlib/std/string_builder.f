// Mutable string builder for efficient string construction.
// Uses a growable byte buffer backed by the allocator pattern.
// Designed to support future string interpolation.

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

// Append a single byte to the builder.
pub fn append_byte(sb: &StringBuilder, b: u8) {
    sb.reserve(1)
    const dest = sb.ptr + sb.len
    dest.* = b
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

// Return the current contents as a String.
// The returned String points into the builder's buffer and is only
// valid while the builder is alive and not modified.
pub fn as_string(sb: &StringBuilder) String {
    return String {
        ptr = sb.ptr,
        len = sb.len,
    }
}

// Return a copy of the current contents as a null-terminated String.
// Allocates from the builder's own allocator.
pub fn to_string(sb: &StringBuilder) String {
    return sb.to_string(sb.get_allocator())
}

// Return a copy of the current contents as a null-terminated String.
// Allocates from the given allocator.
pub fn to_string(sb: &StringBuilder, allocator: &Allocator) String {
    const buf = allocator.alloc(sb.len + 1, 1).expect("StringBuilder.to_string: allocation failed")
    if (sb.len > 0) {
        memcpy(buf.ptr, sb.ptr, sb.len)
    }
    // Null-terminate for C FFI compatibility
    const term = buf.ptr + sb.len
    term.* = 0
    return String {
        ptr = buf.ptr,
        len = sb.len,
    }
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
