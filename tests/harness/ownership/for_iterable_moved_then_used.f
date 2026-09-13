//! TEST: for_iterable_moved_then_used
//! COMPILE-ERROR: E2123 `d` was moved
//! EXIT: 1

import std.allocator
import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

pub fn deinit(self: &FileHandle, allocator: &Allocator) {
}

// `iter(self: Drain)` takes its receiver by value, so `for h in d` is the inferred move of `d`.
pub fn main() i32 {
    let xs: List(FileHandle) = list(1)
    defer xs.deinit()
    let d = xs.drain()
    for h in d {
    }
    return d.taken as i32
}
