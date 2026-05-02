//! TEST: error_e1010_for_paren
//! COMPILE-ERROR: E1010

// Parens around the `for` header are not allowed (RFC-006).
pub fn main() i32 {
    for (i in 0..5) {
        return i
    }
    return 0
}
