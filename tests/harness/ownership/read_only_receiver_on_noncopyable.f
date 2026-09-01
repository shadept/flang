//! TEST: read_only_receiver_on_noncopyable
//! EXIT: 3

import std.option

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// A read-only method reaches a non-copyable receiver only through `&T`, which is
// what keeps `is_some` callable here.
pub fn main() i32 {
    let o: FileHandle? = Some(open(3))
    if !o.is_some() {
        return 1
    }
    return 3
}
