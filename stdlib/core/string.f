// String - Non-owning UTF-8 string view
//
// A lightweight, non-owning view into UTF-8 encoded text. Binary-compatible
// with u8[] slice (same layout: ptr + len). String literals produce this type.
//
// For owned strings that manage their own memory, see [std.string.OwnedString].
//
// Layout:
//   - ptr: pointer to first byte (null-terminated for C FFI)
//   - len: length in bytes (does not include null terminator)

import core.cmp
import core.option
import core.slice

#foreign fn __flang_strlen(ptr: &u8) usize

pub type String = struct {
    ptr: &u8,
    len: usize
}

pub fn from_c_string(ptr: &u8, len: usize? = null) String {
    let l = len match {
        Some(l) => l
        None => __flang_strlen(ptr)
    }
    return .{ ptr = ptr, len = l }
}

// Returns the string contents as a raw byte slice.
pub fn as_raw_bytes(s: String) u8[] {
    return slice_from_raw_parts(s.ptr, s.len)
}

pub fn get(s: String, idx: usize) u8? {
    if idx >= s.len {
        return null
    }
    const ptr = s.ptr + idx
    return ptr.*
}

// Returns the byte at the given index. Panics if out of bounds.
pub fn op_index(s: String, idx: usize) u8 {
    if idx >= s.len {
        panic("index out of bounds")
    }
    const ptr = s.ptr + idx
    return ptr.*
}

// Returns a substring for the given range. Out-of-bounds ranges are clamped
// to string boundaries; inverted ranges (start > end) return empty string.
pub fn op_index(s: String, range: Range(usize)) String {
    let start = range.start
    let end = range.end

    if start > s.len { start = s.len }
    if end > s.len { end = s.len }
    if start > end { end = start }

    return .{ ptr = s.ptr + start, len = end - start }
}

// Compares two strings for byte-wise equality.
pub fn op_eq(a: String, b: String) bool {
    if a.ptr == b.ptr and a.len == b.len {
        return true
    }

    if a.len != b.len {
        return false
    }

    const len = if a.len < b.len { a.len } else { b.len }
    for idx in 0..len {
        if a[idx] != b[idx] {
            return false
        }
    }

    return true
}

// Lexicographic byte-wise comparison. Shorter strings compare less than
// longer strings with the shorter as a prefix (standard lexicographic order).
pub fn op_cmp(a: String, b: String) Ord {
    if a.ptr == b.ptr and a.len == b.len {
        return Ord.Equal
    }

    const min_len = if a.len < b.len { a.len } else { b.len }
    for idx in 0..min_len {
        const ab = a[idx]
        const bb = b[idx]
        if ab < bb { return Ord.Less }
        if ab > bb { return Ord.Greater }
    }

    if a.len < b.len { return Ord.Less }
    if a.len > b.len { return Ord.Greater }
    return Ord.Equal
}

pub fn hash(s: String) usize {
    let h: usize = 14695981039346656037
    for i in 0..s.len as isize {
        const byte: &u8 = s.ptr + (i as usize)
        h = (h ^ (byte.* as usize)) * 1099511628211
    }
    return h
}
