//! TEST: copy_via_list_get
//! COMPILE-ERROR: E2134 copy_via_list_get.f
//! EXIT: 1

import std.collections.list
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

// `get` copies its element, so it requires `T: copyable`: the error names this file, not
// `stdlib/std/list.f`.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    let got = xs.get(0)
    return got.unwrap().fd
}
