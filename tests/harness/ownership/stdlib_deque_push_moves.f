//! TEST: stdlib_deque_push_moves
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.collections.deque

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
    let q: Deque(FileHandle) = deque(2)
    let h = open(3)
    q.push_back(h)
    q.push_front(open(4))
    return h.fd                    // error E2123
}
