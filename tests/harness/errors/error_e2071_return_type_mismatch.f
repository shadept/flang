//! TEST: error_e2071_return_type_mismatch
//! COMPILE-ERROR: E2071

fn add(a: i32, b: i32) i32 {
    return "hello"
}

pub fn main() i32 {
    return 0
}
