//! TEST: interp_literal_braces
//! EXIT: 0
//! STDOUT: { 42 }

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let x = 42i32
    let msg = $"{{ {x} }}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
