//! TEST: set_index_moves_value
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.collections.dict

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

pub fn main() i32 {
    let d: Dict(i32, FileHandle) = dict()
    let h = open(3)
    d[1] = h                           // `op_set_index(d, 1, h)` takes `h`
    return h.fd                        // error E2123
}
