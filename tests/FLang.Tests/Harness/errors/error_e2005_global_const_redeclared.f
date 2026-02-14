//! TEST: error_e2005_global_const_redeclared
//! COMPILE-ERROR: E2005

const X: i32 = 10
const X: i32 = 20

pub fn main() i32 {
    return X
}
