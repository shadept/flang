// String type - UTF-8 view, always null-terminated for C FFI
// Binary-compatible with u8[] slice

import core.option

pub struct String {
    ptr: &u8,
    len: usize
}

pub fn op_index(s: String, idx: usize) u8? {
    if (s.len < idx) {
        return null
    }
    if (idx >= s.len) {
        return null
    }
    const elem = s.ptr + idx
    return elem.*
}

pub fn op_eq(a: String, b: String) bool {
    if (a.len != b.len) {
        return false
    }

    const len = min(a.len, b.len)
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

pub fn op_ne(a: String, b: String) bool {
    return !op_eq(a, b)
}
