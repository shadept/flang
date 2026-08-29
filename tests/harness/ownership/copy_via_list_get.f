//! TEST: copy_via_list_get
//! COMPILE-ERROR: E2123 copy_via_list_get.f
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

// `get` returns the element by value while it stays in the list, so the result
// is a second owner. The error must name THIS line, not `stdlib/std/list.f`.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    let got = xs.get(0)
    return got.unwrap().fd
}
