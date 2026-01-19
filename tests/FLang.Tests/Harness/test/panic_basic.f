//! TEST: panic_basic
//! EXIT: 1
//! STDOUT: panic test message

import core.panic

pub fn main() i32 {
    panic("panic test message")
    return 0
}
