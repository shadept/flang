//! TEST: error_e2070_default_param_type_mismatch
//! COMPILE-ERROR: E2070

fn greet(name: &u8 = null) i32 {
    return 0
}

pub fn main() i32 {
    return greet()
}
