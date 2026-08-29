//! TEST: move_field_through_reference
//! COMPILE-ERROR: E2126
//! EXIT: 1
//! SKIP: RFC-027 not implemented

import std.list

// A reference does not grant rights the module does not have.
fn steal(l: &List(i32)) i32 {
    let p = move l.ptr             // error E2126
    return 0
}

pub fn main() i32 {
    let l: List(i32) = list(2)
    return steal(&l)
}
