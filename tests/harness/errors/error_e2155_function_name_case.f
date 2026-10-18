//! TEST: error_e2155_function_name_case
//! COMPILE-ERROR: E2155

// A function's name starts lowercase or `_` (RFC-039).
fn Compute() i32 {
    return 1
}

pub fn main() i32 {
    return Compute()
}
