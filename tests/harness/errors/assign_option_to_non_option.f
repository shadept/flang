//! TEST: assign_option_to_non_option
//! COMPILE-ERROR: E2002
//! EXIT: 1

// Regression: assigning an `Option(T)` value into a `T` slot must be a
// type error. The symmetric `OptionWrappingCoercionRule` (T <-> Option(T))
// previously made the type checker silently accept this in both `return`
// and assignment contexts. The `return` direction has its own test in
// match_return_pattern_bound_mismatch.f; this one covers assignment.

import std.option

fn maybe() i32? { return Some(1) }

pub fn main() i32 {
    let x: i32 = 0
    x = maybe()    // assigning Option(i32) into an i32 slot — must error
    return x
}
