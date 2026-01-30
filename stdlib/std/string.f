// TODO file doc

// =============================================================================
// String
// =============================================================================

import core.string
import std.option

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
// Bytes Iterator
// =============================================================================

struct Bytes {
    buf: u8[]
    idx: usize
}

pub fn bytes(s: String) Bytes {
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

struct Chars {
    buf: u8[]
    idx: usize
}

pub fn chars(s: String) Chars {
    // TODO fix String to Slice(u8) coersion
    const slice = slice_from_raw_parts(s.ptr, s.len)
    return .{ buf = slice, idx = 0 }
}

pub fn iter(c: &Chars) Chars {
    return c.*
}

pub fn next(it: &Chars) u8? {
    if (it.idx >= it.buf.len) {
        return null
    }

    const elem = it.buf[it.idx]
    it.idx = it.idx + 1
    return elem
}


pub fn hash(s: String) usize {
    //let mut hash = 5381;
    //for (c in s.bytes()) {
    //    hash = ((hash << 5) + hash) + c as usize
    //}
    //hash
    return 0
}
