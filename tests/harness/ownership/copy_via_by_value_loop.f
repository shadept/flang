//! TEST: copy_via_by_value_loop
//! COMPILE-ERROR: E2124 copy_via_by_value_loop.f
//! EXIT: 1

import std.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// The copy happens inside a `std.list` body. The error must name a line in this
// file, not the container's source.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    for h in xs {
        return h.fd
    }
    return 0
}
