//! TEST: interp_literal_braces
//! EXIT: 0
//! STDOUT: { 42 }

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let x = 42i32
    let msg = $"{{ {x} }}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
