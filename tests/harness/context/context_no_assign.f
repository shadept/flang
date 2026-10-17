//! TEST: context_no_assign
//! COMPILE-ERROR: E2149
//! EXIT: 1

context level: i32 = 0

pub fn main() i32 {
    context.level = 3 // error E2149: rebind instead
    return 0
}
