//! TEST: interp_capacity_form
//! EXIT: 0
//! STDOUT: hi alice

import std.io.print
import std.string_builder
import std.string

pub fn main() i32 {
    let who = "alice"
    let msg = $(64)"hi {who}"
    defer msg.deinit()
    print(msg.view)
    return 0
}
