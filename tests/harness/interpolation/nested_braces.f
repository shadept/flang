//! TEST: interp_nested_braces
//! EXIT: 0
//! STDOUT: val=5

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let msg = $"val={ {
        let x = 5i32
        x
    } }"
    defer msg.deinit()
    print(msg.view)
    return 0
}
