//! TEST: interp_format_spec_hex
//! EXIT: 0
//! STDOUT: ff

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let n = 255u8
    let msg = $"{n:x}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
