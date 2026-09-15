//! TEST: stdlib_list_push_moves
//! COMPILE-ERROR: E2123
//! EXIT: 1

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

// `push` takes ownership of its element.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    let h = open(3)
    xs.push(h)
    return h.fd                    // error E2123
}
