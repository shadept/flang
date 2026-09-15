//! TEST: read_only_receiver_on_noncopyable
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

// A read-only method on a non-copyable receiver: `is_some` takes `&self`, and the binding stays
// live.
pub fn main() i32 {
    let o: FileHandle? = Some(open(3))
    if !o.is_some() {
        return 1
    }
    return 3
}
