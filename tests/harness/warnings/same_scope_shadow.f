//! TEST: same_scope_shadow
//! COMPILE-WARNING: W1002
//! EXIT: 0

pub fn main() i32 {
    const val: i32 = 1
    const val: i32 = 2
    return val - 2
}
