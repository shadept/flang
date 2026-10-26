//! TEST: released_match_read_keeps_owner
//! NO-COMPILE-WARNING: W2006 `o`
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

// A match that only reads leaves `o` live and whole, so it can still be released after.
pub fn main() i32 {
    let o: FileHandle? = Some(open(3))
    const fd = o match {
        Some(h) => h.fd
        None => 0
    }
    o match {
        Some(h) => {
            const _c = close(h)
        }
        None => {}
    }
    return fd
}
