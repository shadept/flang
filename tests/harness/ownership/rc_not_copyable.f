//! TEST: rc_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.rc

// A handle holds one count: a bitwise copy would release it twice. A second handle is `retain`.
pub fn main() i32 {
    let r = rc(7i32)
    let r2 = r // error E2124
    r2.deinit()
    return 0
}
