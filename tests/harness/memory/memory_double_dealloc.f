//! TEST: memory_double_dealloc
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.allocator
import std.option

pub fn main() i32 {
    const a = context.allocator
    const m = a.alloc(16, 8).unwrap()
    a.dealloc(m)
    a.dealloc(m) // error E2123: `m` went back to the allocator above
    return 0
}
