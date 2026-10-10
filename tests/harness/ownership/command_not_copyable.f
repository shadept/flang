//! TEST: command_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.process

// A command owns its argument and environment strings.
pub fn main() i32 {
    let c = command("true")
    let d = c // error E2124
    d.deinit()
    return 0
}
