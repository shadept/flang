//! TEST: container_element_deinit_runs
//! EXIT: 2

import std.allocator
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

let calls: i32 = 0

fn deinit(self: FileHandle, allocator: &Allocator) {
    calls = calls + 1
}

// A container instantiated here reaches the element's private `deinit`.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    xs.push(open(4))
    xs.deinit()
    return calls
}
