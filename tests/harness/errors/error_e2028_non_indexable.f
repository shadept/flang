//! TEST: error_e2028_non_indexable
//! COMPILE-ERROR: E2028

pub fn main() i32 {
    let x: i32 = 42
    let val: i32 = x[0]  // ERROR: cannot index into value of type `i32`
    return val
}
