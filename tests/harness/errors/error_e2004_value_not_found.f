//! TEST: error_e2004_value_not_found
//! COMPILE-ERROR: E2004

pub fn main() i32 {
    return undefined_variable  // ERROR: cannot find value `undefined_variable` in this scope
}
