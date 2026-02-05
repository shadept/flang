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

import core.option
import core.slice

pub struct String {
    ptr: &u8,
    len: usize
}

pub fn get(s: String, idx: usize) u8? {
    if (idx >= s.len) {
        return null
    }
    const ptr = s.ptr + idx
    return ptr.*
}

// Returns the string contents as a raw byte slice.
pub fn as_raw_slice(s: String) u8[] {
    return slice_from_raw_parts(s.ptr, s.len)
}

// Returns the byte at the given index. Panics if out of bounds.
pub fn op_index(s: String, idx: usize) u8 {
    if (idx >= s.len) {
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

    if (start > s.len) { start = s.len }
    if (end > s.len) { end = s.len }
    if (start > end) { end = start }

    return String { ptr = s.ptr + start, len = end - start }
}

// Compares two strings for byte-wise equality.
pub fn op_eq(a: String, b: String) bool {
    if (a.ptr == b.ptr and a.len == b.len) {
        return true
    }

    if (a.len != b.len) {
        return false
    }

    const len = if (a.len < b.len) a.len else b.len
    for (i in 0..len) {
        let idx: usize = i as usize
        let ca: u8? = a[idx]
        let cb: u8? = b[idx]
        if (ca.value != cb.value) {
            return false
        }
    }

    return true
}

pub fn hash(s: String) usize {
    //let mut hash = 5381;
    //for (c in s.bytes()) {
    //    hash = ((hash << 5) + hash) + c as usize
    //}
    //hash
    return 0
}
