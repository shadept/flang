//! TEST: error_e2012_cannot_deref
//! COMPILE-ERROR: E2012

pub fn main() i32 {
    let x: i32 = 42
    return x.*  // ERROR: cannot dereference non-reference type
}
