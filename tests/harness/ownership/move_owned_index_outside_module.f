//! TEST: move_owned_index_outside_module
//! COMPILE-ERROR: E2125 `move` takes from
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

// `UnmanagedList.ptr` is `owned`, but it is `std.collections.list`'s: an element behind it is the
// list's to hand over, and from here the index is refused (RFC-032).
pub fn main() i32 {
    let xs: List(FileHandle) = list(1)
    xs.push(open(3))
    return close(move (xs.ptr + 0usize).*)
}
