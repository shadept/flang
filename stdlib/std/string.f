// TODO file doc

import core.string // explicit import for clarity

import std.encoding.utf8
import std.allocator
import std.option

// =============================================================================
// String stdlib functions
// =============================================================================

// **1. String manipulation (HIGH PRIORITY)**
// - `split()`, `trim()`, `find()`, `contains()`, `replace()`
// - `ends_with()` (commented out)
// - Substring search
// - Character classification (`is_digit`, `is_alpha`, `is_whitespace`)
// - String-to-integer parsing (`parse_int`)

pub fn find(s: String, needle: String) usize? {
    let h = s.as_raw_bytes()
    let n = needle.as_raw_bytes()

    if n.len == 0 {
        return 0
    }
    if n.len > h.len {
        return null
    }

    // Build table
    // Would need to support dynamic stack allocated arrays
    let table = [0usize; 1024] // TODO support dynamic stack allocations and replace 1024 with n.len
    let j: usize = 0 // TODO handle multi statement inference
    for (i in 1..n.len) {
        loop {
            if n[i] == n[j] {
                j = j + 1
                table[i] = j
                break
            }
            if j == 0 {
                table[i] = 0
                break
            }
            j = table[j - 1]
        }
    }

    // Search
    j = 0
    for (i in 0..h.len) {
        loop {
            if h[i] == n[j] {
                j = j + 1
                if j == n.len {
                    return i - n.len + 1
                }
                break
            }
            if j == 0 {
                break
            }
            j = table[j - 1]
        }
    }

    return null
}

pub fn starts_with(s: String, prefix: String) bool {
    if (s.len < prefix.len) {
        return false
    }
    for (i in 0..prefix.len) {
        const i = i as usize
        if (s[i] != prefix[i]) {
            return false
        }
    }
    return true
}

// pub fn ends_with(s: String, suffix: String) bool {
//     if (s.len < suffix.len) {
//         return false
//     }
//     for (i in 0..suffix.len) {
//         if (s[s.len - i - 1] != suffix[suffix.len - i - 1]) {
//             return false
//         }
//     }
//     return true
// }


// =============================================================================
// OwnedString
// =============================================================================

pub type OwnedString = struct {
    ptr: &u8
    len: usize
    allocator: &Allocator?
}

pub fn deinit(self: &OwnedString) {
    self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.len))
    self.ptr = 0usize as &u8
    self.len = 0
}

pub fn as_view(self: OwnedString) String {
    return .{ ptr = self.ptr, len = self.len }
}

// =============================================================================
// Bytes Iterator
// =============================================================================

type Bytes = struct {
    buf: u8[]
    idx: usize
}

pub fn bytes(s: String) Bytes {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn bytes(s: OwnedString) Bytes {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn iter(b: &Bytes) Bytes {
    // TODO allow iter without reference
    return b.*
}

pub fn next(it: &Bytes) u8? {
    if (it.idx >= it.buf.len) {
        return null
    }

    const elem = it.buf[it.idx]
    it.idx = it.idx + 1
    return elem
}

// =============================================================================
// Chars Iterator
// =============================================================================

type Chars = struct {
    buf: u8[]
    idx: usize
}

pub fn chars(s: String) Chars {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn chars(s: OwnedString) Chars {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn iter(c: &Chars) Chars {
    return c.*
}

pub fn next(it: &Chars) char? {
    if (it.idx >= it.buf.len) {
        return null
    }

    const res = decode_char(it.buf[it.idx..])
    it.idx = it.idx + res.1
    return res.0
}
