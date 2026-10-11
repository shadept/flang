//! TEST: sort_reads_owning_elements
//! EXIT: 0

import std.collections.list
import std.sort

// One comparator shape for every element type: `fn(T, T) Ord` reads both operands where they lie,
// so an owning element sorts by `op_cmp` or by an unannotated lambda with no copy.
type Handle = struct {
    owned fd: i32
}

pub fn deinit(self: move Handle) {}

pub fn op_cmp(a: Handle, b: Handle) Ord {
    return op_cmp(a.fd, b.fd)
}

pub fn main() i32 {
    let xs: List(Handle) = list(3)
    defer xs.deinit()
    xs.push(Handle { fd = 9 })
    xs.push(Handle { fd = 2 })
    xs.push(Handle { fd = 5 })
    xs.sort()
    if xs[0].fd != 2 or xs[2].fd != 9 {
        return 1
    }
    xs.sort(fn(a, b) { op_cmp(b.fd, a.fd) })
    if xs[0].fd != 9 or xs[2].fd != 2 {
        return 2
    }
    return 0
}
