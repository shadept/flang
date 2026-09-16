//! TEST: interp_string_in_hole
//! EXIT: 0
//! STDOUT: hello, WORLD!

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let word = "WORLD"
    let msg = $"hello, {word}!"
    defer msg.deinit()
    print(msg.view)
    return 0
}
