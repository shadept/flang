//! TEST: interp_expr_in_hole
//! EXIT: 0
//! STDOUT: result=1

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let c = true
    let msg = $"result={ if c { 1i32 } else { 2i32 } }"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
