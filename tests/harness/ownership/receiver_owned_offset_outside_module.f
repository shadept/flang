//! TEST: receiver_owned_offset_outside_module
//! COMPILE-ERROR: E2125 belongs to its container
//! EXIT: 1

import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// The list's `owned` buffer is `list.f`'s to take from; the receiver form gets no more than the
// explicit `move` does.
pub fn main() i32 {
    let xs: List(FileHandle) = list(1)
    xs.push(open(3))
    return (xs.ptr + 0usize).*.close()
}
