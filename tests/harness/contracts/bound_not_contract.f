//! TEST: bound_not_contract
//! COMPILE-ERROR: E2135
//! EXIT: 1

type Point = struct {
    x: i32
}

fn f(x: $T) where T: Point {} // error E2135

pub fn main() i32 {
    return 0
}
