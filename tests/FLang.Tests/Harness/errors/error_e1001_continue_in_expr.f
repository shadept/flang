//! TEST: error_e1001_continue_in_expr
//! COMPILE-ERROR: E1001

// continue must not be valid in arbitrary expression position
pub fn main() i32 {
    let x = 1 + continue
    return 0
}
