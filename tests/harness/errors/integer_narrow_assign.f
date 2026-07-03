//! TEST: integer_narrow_assign
//! COMPILE-ERROR: E2002
//! EXIT: 1

// Narrowing in an assignment must be rejected.

pub fn main() i32 {
    let x: i32 = 0
    x = 5i64   // i64 -> i32 narrowing must error
    return x
}
