//! TEST: op_try_incompatible_return
//! COMPILE-ERROR: E2071
//! EXIT: 1

import std.option

fn maybe() i32? { return Some(1) }

// `?` early-returns `Option(i32)`, which is not assignable to `i32`.
fn caller() i32 {
    let x = maybe()?
    return x
}

pub fn main() i32 {
    return caller()
}
