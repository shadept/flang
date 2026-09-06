//! TEST: interp_format_spec_int
//! EXIT: 0
//! STDOUT: 0042

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let n = 42i32
    let msg = $"{n:04}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
