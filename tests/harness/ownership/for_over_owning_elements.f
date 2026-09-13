//! TEST: for_over_owning_elements
//! COMPILE-ERROR: E2999 drain
//! EXIT: 1

import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn deinit(self: &FileHandle, allocator: &Allocator) {
}

// `for x in xs` copies each element out; over an owning element type that is the slice iterator's
// `#error`, pointing at `for &x in xs` and `xs.drain()`.
pub fn main() i32 {
    let xs: List(FileHandle) = list(1)
    defer xs.deinit()
    xs.push(open(3))
    let n: i32 = 0
    for h in xs {
        n = n + h.fd
    }
    return n
}
