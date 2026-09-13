//! TEST: drain_loop_moves_the_variable
//! EXIT: 2

import std.allocator
import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

pub fn deinit(self: &FileHandle, allocator: &Allocator) {
}

// A `for` variable is bound anew on every iteration, so moving it in the body says nothing about
// the next one: `for x in xs.drain() { ys.push(move x) }` is the loop that hands elements over.
pub fn main() i32 {
    let src: List(FileHandle) = list(2)
    let dst: List(FileHandle) = list(2)
    defer dst.deinit()
    src.push(open(1))
    src.push(open(2))
    for h in src.drain() {
        dst.push(move h)
    }
    src.deinit()
    return dst.len as i32
}
