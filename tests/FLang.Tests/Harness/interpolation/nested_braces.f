//! TEST: interp_nested_braces
//! EXIT: 0
//! STDOUT: val=5

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let msg = $"val={ { let x = 5i32; x } }"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
