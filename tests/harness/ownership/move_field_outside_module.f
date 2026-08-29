//! TEST: move_field_outside_module
//! COMPILE-ERROR: E2126
//! EXIT: 1
//! SKIP: RFC-027 not implemented

import std.list

// `List` is declared in stdlib/std/list.f, so its fields cannot be moved from
// here -- the same rule that makes them unwritable (E2114).
pub fn main() i32 {
    let l: List(i32) = list(2)
    let p = move l.ptr             // error E2126
    return 0
}
