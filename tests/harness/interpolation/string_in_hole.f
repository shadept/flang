//! TEST: interp_string_in_hole
//! EXIT: 0
//! STDOUT: hello, WORLD!

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let word = "WORLD"
    let msg = $"hello, {word}!"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
