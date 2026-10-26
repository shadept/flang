//! TEST: released_match_spends_owner
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

// Moving the payload out spends `o`; the `None` arm leaves it holding nothing.
fn take(o: move FileHandle?) i32 {
    return o match {
        Some(h) => close(h)
        None => 0
    }
}

pub fn main() i32 {
    return take(Some(open(3)))
}
