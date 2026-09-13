//! TEST: drain_loop_return_releases
//! EXIT: 21

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

// A `return` from inside the loop fires the release on its way out, like any defer: the untaken
// tail is back in the list by the time the caller reads it.
fn first_big(xs: &List(FileHandle)) i32 {
    for h in xs.drain() {
        if h.fd > 1 {
            return h.fd
        }
    }
    return 0
}

pub fn main() i32 {
    let xs: List(FileHandle) = list(3)
    defer xs.deinit()
    xs.push(open(1))
    xs.push(open(2))
    xs.push(open(3))
    const got = first_big(&xs)
    return got * 10 + (xs.len as i32)
}
