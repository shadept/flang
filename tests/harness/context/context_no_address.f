//! TEST: context_no_address
//! COMPILE-ERROR: E2149
//! EXIT: 1

context level: i32 = 0

pub fn main() i32 {
    const p: &Context = &context // error E2149
    return 0
}
