//! TEST: memory_never_released
//! COMPILE-WARNING: W2006 `m` is never released
//! EXIT: 0

import std.allocator
import std.option

pub fn main() i32 {
    const m = context.allocator.alloc(16, 8).unwrap()
    return 0 // warning W2006: the block is never given back
}
