// String type - UTF-8 view, always null-terminated for C FFI
// Binary-compatible with u8[] slice
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

    for (i in 0..a.len) {
        if (a[i] != b[i]) {
            return false
        }
    }

    return true
}
