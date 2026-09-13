//! TEST: for_iterable_explicit_move
//! COMPILE-ERROR: E2128 drop the `move`
//! EXIT: 1

import std.allocator
import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

pub fn deinit(self: &FileHandle, allocator: &Allocator) {
}

// The iterable position is already the move; there is no second spelling of it.
pub fn main() i32 {
    let xs: List(FileHandle) = list(1)
    defer xs.deinit()
    let d = xs.drain()
    for h in move d {
    }
    return 0
}
