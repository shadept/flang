//! TEST: append_hex
//! EXIT: 0
//! STDOUT: ff

import core.string
import core.io
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(null)
    sb.append(255u32, "x")
    println(sb.as_view())
    sb.deinit()
    return 0
}
