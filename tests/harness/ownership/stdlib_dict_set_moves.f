//! TEST: stdlib_dict_set_moves
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.collections.dict

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let d: Dict(i32, FileHandle) = dict()
    let h = open(3)
    d.set(1, h)
    return h.fd                    // error E2123
}
