//! TEST: context_no_value
//! COMPILE-ERROR: E2149
//! EXIT: 1

context level: i32 = 0

pub fn main() i32 {
    const saved = context                                // error E2149: not a value
    return 0
}
