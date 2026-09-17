//! TEST: sort_owning_elements
//! EXIT: 2

import std.collections.list

type Handle = struct {
    owned fd: i32
}

pub fn deinit(self: move Handle) {
}

pub fn op_cmp(a: &Handle, b: &Handle) Ord {
    return op_cmp(a.fd, b.fd)
}

// Sorting moves elements through `swap`, whose `&move` slots take from one place and refill it from
// the other - no copy, and no byte-level helper.
pub fn main() i32 {
    let xs: List(Handle) = list(3)
    xs.push(Handle { fd = 9 })
    xs.push(Handle { fd = 2 })
    xs.push(Handle { fd = 5 })
    xs.sort()
    const first = xs[0].fd
    if xs[2].fd != 9 {
        return 30
    }
    xs.deinit()
    return first
}
