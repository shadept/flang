//! TEST: integer_narrow_arg
//! COMPILE-ERROR: E2011
//! EXIT: 1

// Narrowing in a function argument must be rejected.

fn take(n: i32) i32 { return n }

pub fn main() i32 {
    let big: i64 = 5i64
    return take(big)   // i64 -> i32 narrowing in arg position must error
}
