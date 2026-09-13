//! TEST: drain_loop_break_keeps_tail
//! EXIT: 13

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

// `break` leaves the loop through the exit block, where the drain is released once: the untaken
// element is back in the list, at the front, and the list's length is what is left.
pub fn main() i32 {
    let xs: List(FileHandle) = list(3)
    defer xs.deinit()
    xs.push(open(1))
    xs.push(open(2))
    xs.push(open(3))
    let seen: i32 = 0
    for h in xs.drain() {
        seen = seen + h.fd
        if h.fd == 2 {
            break
        }
    }
    if seen != 3 {
        return 99
    }
    return (xs.len as i32) * 10 + xs[0].fd
}
