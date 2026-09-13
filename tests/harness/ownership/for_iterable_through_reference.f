//! TEST: for_iterable_through_reference
//! COMPILE-ERROR: E2128 reached through a reference
//! EXIT: 1

import std.allocator
import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

pub fn deinit(self: &FileHandle, allocator: &Allocator) {
}

// A by-value `iter` on a `&Drain` would read the drain out of storage the loop does not own.
fn count(d: &Drain(FileHandle)) i32 {
    let n: i32 = 0
    for h in d {
        n = n + 1
    }
    return n
}

pub fn main() i32 {
    let xs: List(FileHandle) = list(1)
    defer xs.deinit()
    let d = xs.drain()
    return count(&d)
}
