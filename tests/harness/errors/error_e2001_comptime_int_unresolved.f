//! TEST: comptime_int_unresolved_error
//! COMPILE-ERROR: E2001

pub fn main() i32 {
    let c = 10
    let d = c
    return 0
}
