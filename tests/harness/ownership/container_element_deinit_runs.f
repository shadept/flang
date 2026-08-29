//! TEST: container_element_deinit_runs
//! EXIT: 2
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

let calls: i32 = 0

fn deinit(self: FileHandle) {
    calls = calls + 1
}

// The element loop deinits each live element through a pointer.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    xs.push(open(4))
    (move xs).deinit()
    return calls
}
