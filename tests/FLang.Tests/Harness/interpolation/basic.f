//! TEST: interp_basic
//! EXIT: 0
//! STDOUT: hello world

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let name = "world"
    let msg = $"hello {name}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
