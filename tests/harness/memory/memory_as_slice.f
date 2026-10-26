//! TEST: memory_as_slice
//! EXIT: 6

import std.allocator
import std.option

pub fn main() i32 {
    const a = context.allocator
    const m = a.alloc(3 * size_of(i32), align_of(i32)).unwrap()
    defer a.dealloc(m)
    const xs: i32[] = m.as_slice()
    xs[0] = 1i32
    xs[1] = 2i32
    xs[2] = 3i32
    return xs[0] + xs[1] + xs[2]
}
