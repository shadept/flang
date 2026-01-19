//! TEST: error_e2038_const_reassign
//! COMPILE-ERROR: E2038
pub fn main() i32 {
    const x: i32 = 42
    x = 50
    return x
}
