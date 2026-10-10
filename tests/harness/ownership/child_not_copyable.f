//! TEST: child_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.process
import std.result

// A child owns its process handle, as a file owns its descriptor: a second binding would release it
// twice.
pub fn main() i32 {
    let cmd = command("true")
    defer cmd.deinit()
    let c = cmd.spawn().unwrap()
    let d = c // error E2124
    d.deinit()
    return 0
}
