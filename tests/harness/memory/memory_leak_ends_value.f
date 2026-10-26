//! TEST: memory_leak_ends_value
//! NO-COMPILE-WARNING: W2006 `m`
//! EXIT: 0

import std.allocator
import std.option

pub fn main() i32 {
    const m = context.allocator.alloc(16, 8).unwrap()
    leak(m) // given up on purpose: `m` ends here
    return 0
}
