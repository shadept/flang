//! TEST: integer_narrow_return
//! COMPILE-ERROR: E2071
//! EXIT: 1

// Narrowing at a return statement must be rejected.

fn caller() i32 {
    return 5i64   // i64 -> i32 narrowing must error
}

pub fn main() i32 { return caller() }
