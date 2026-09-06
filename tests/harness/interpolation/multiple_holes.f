//! TEST: interp_multiple_holes
//! EXIT: 0
//! STDOUT: 2+3=5

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let a = 2i32
    let b = 3i32
    let msg = $"{a}+{b}={a+b}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
