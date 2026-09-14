//! TEST: for_ref_loop
//! EXIT: 3
//! SKIP: RFC-033 step 6 - `List.push` takes `value: move T`

import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn deinit(self: move FileHandle) {}

// The reference form binds `&FileHandle`, so the loop does not copy.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    let total = 0
    for &h in xs {
        total = total + h.fd
    }
    return total
}
