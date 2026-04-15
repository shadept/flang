//! TEST: error_e1001_break_in_expr
//! COMPILE-ERROR: E1001

// break must not be valid in arbitrary expression position
pub fn main() i32 {
    let x = 1 + break
    return 0
}
