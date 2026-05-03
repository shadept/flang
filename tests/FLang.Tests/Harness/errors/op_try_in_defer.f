//! TEST: op_try_in_defer
//! COMPILE-ERROR: E2091
//! EXIT: 1

import std.option

fn maybe() i32? { return Some(1) }

fn caller() i32? {
    defer {
        let x = maybe()?
    }
    return Some(0)
}

pub fn main() i32 {
    return 0
}
