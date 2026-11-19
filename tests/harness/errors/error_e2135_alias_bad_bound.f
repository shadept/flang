//! TEST: error_e2135_alias_bad_bound
//! COMPILE-ERROR: E2135
//! EXIT: 1

import std.collections.list

// An alias's bound is reported at the declaration, whether or not the alias is used.
type Shelf(T: i32) = List(T) // error E2135

pub fn main() i32 {
    return 0
}
