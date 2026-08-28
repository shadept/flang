//! TEST: literal_settling_on_nominal_error
//! COMPILE-ERROR: E2102

import std.option

// There is no implicit `T -> Option(T)` (spec 3.3, ADR-0005), so the literal has
// no numeric type to settle on. An unsuffixed literal reaches its verdict through
// the pending-literal sweep rather than through unification, which is the path
// this pins.
pub fn main() i32 {
    let v: i32? = 42
    return 0
}
