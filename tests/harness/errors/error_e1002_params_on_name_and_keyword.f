//! TEST: error_e1002_params_on_name_and_keyword
//! COMPILE-ERROR: E1002

// Type parameters go on the name only (RFC-047).
type Pair(T) = struct(U) { // error[E1002]
    a: T
    b: U
}

pub fn main() i32 {
    return 0
}
