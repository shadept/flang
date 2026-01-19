//! TEST: error_e2018_struct_ctor_non_struct
//! COMPILE-ERROR: E2018

pub fn main() i32 {
    let x: i32 = i32 { value = 42 }  // ERROR: i32 is not a struct
    return x
}
