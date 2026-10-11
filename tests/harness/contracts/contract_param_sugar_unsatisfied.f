//! TEST: contract_param_sugar_unsatisfied
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.option

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

fn drain(it: move Iter) i32 {
    return 0
}

pub fn main() i32 {
    return drain(3i32) // error E2134: `i32` has no `next`
}
