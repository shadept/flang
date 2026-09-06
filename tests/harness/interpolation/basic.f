//! TEST: interp_basic
//! EXIT: 0
//! STDOUT: hello world

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let name = "world"
    let msg = $"hello {name}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
