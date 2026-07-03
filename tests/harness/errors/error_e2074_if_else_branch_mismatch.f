//! TEST: error_e2074_if_else_branch_mismatch
//! COMPILE-ERROR: E2074

fn get_int() i32 { return 42 }

pub fn main() i32 {
    let x = if true { get_int() } else { "hello" }
    return 0
}
