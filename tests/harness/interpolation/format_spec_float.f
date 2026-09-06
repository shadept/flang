//! TEST: interp_format_spec_float
//! EXIT: 0
//! STDOUT: 3.14

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let n = 3.14f64
    let msg = $"{n:.2}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
