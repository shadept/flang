//! TEST: consume_foreign_field_refused
//! COMPILE-ERROR: E2127
//! EXIT: 1

import std.collections.list

fn sink(s: move UnmanagedList(i32)) {}

// The right is the declaring module's: std's list storage cannot be handed to a consumer from here.
fn steal(l: &List(i32)) {
    sink(l.__storage) // error E2127
}

pub fn main() i32 {
    let l: List(i32) = list(2)
    steal(&l)
    return 0
}
