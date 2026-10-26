//! TEST: released_holds_nothing
//! NO-COMPILE-WARNING: W2006 `o`
//! EXIT: 0

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

// `null` and a payload-less variant hold nothing to release.
pub fn main() i32 {
    let o: FileHandle? = null
    return 0
}
