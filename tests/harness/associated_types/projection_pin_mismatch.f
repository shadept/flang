//! TEST: projection_pin_mismatch
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.option

type Counter = struct {
    n: i32
}

fn next(self: &Counter) i32? {
    return null
}

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

fn count(it: move $I) i32 where I: Iter(Item = u8) {
    return 0
}

pub fn main() i32 {
    const c = Counter { n = 0 }
    return count(c) // error E2134: `Counter` yields `i32`, not `u8`
}
