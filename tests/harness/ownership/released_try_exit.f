//! TEST: released_try_exit
//! COMPILE-WARNING: W2006 `h` is never released: it is still live at this `?`
//! EXIT: 3

import std.option

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn first(xs: i32?) i32? {
    let h = open(3)
    const x = xs? // warning W2006: the early exit leaves `h` live
    return Some(close(h) + x)
}

pub fn main() i32 {
    return first(Some(0i32)) ?? 0
}
