//! TEST: copy_via_by_value_loop
//! COMPILE-ERROR: E2123 copy_via_by_value_loop.f
//! EXIT: 1
//! SKIP: RFC-027 not implemented

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

// The copy happens inside `next()`. The error must name the loop, not the
// iterator's source.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    for h in xs {
        return h.fd
    }
    return 0
}
