//! TEST: forgotten_drain_leaks
//! EXIT: 20

import std.allocator
import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

let closed: i32 = 0

pub fn deinit(self: &FileHandle, allocator: &Allocator) {
    closed = closed + 1
}

// A drain that is never released leaks the untaken tail and frees nothing twice: the list stays
// empty, so its own `deinit` walks a length of zero and no element is released behind the drain.
pub fn main() i32 {
    let xs: List(FileHandle) = list(3)
    defer xs.deinit()
    xs.push(open(1))
    xs.push(open(2))
    xs.push(open(3))
    let d = xs.drain()
    let taken: i32 = 0
    d.next() match {
        Some(h) => taken = taken + 1
        None => {}
    }
    d.next() match {
        Some(h) => taken = taken + 1
        None => {}
    }
    return taken * 10 + (xs.len as i32) + closed
}
