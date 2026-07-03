//! TEST: error_e1020_bad_interp_prefix
//! COMPILE-ERROR: E1020

pub fn main() i32 {
    let x = $123"bad prefix"
    return 0
}
