//! TEST: released_match_temporary_part
//! COMPILE-WARNING: W2006 `h` is never released
//! EXIT: 3

import std.option

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    const fd = h.fd
    leak(h)
    return fd
}

fn make() FileHandle? {
    return Some(open(3))
}

// The arm owns what it takes apart from a temporary.
pub fn main() i32 {
    return make() match {
        Some(h) => h.fd // warning W2006: `h` is never released
        None => 0
    }
}
