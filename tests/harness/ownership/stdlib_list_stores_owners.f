//! TEST: stdlib_list_stores_owners
//! EXIT: 12

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

// A temporary and a binding both reach the list through `push` and `insert`.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    let h = open(4)
    xs.insert(0, h)
    xs.push(open(5))
    let total = 0
    for &f in xs {
        total = total + f.fd
    }
    return total
}
