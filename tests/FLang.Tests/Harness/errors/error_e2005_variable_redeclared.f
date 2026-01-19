//! TEST: error_e2005_variable_redeclared
//! COMPILE-ERROR: E2005

pub fn main() i32 {
    let x: i32 = 10
    let x: i32 = 20  // ERROR: variable `x` is already declared
    return x
}
