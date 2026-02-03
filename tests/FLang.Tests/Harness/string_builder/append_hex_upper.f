//! TEST: append_hex_upper
//! EXIT: 0
//! STDOUT: FF

import core.string
import core.io
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(null)
    sb.append(255u32, "X")
    println(sb.as_view())
    sb.deinit()
    return 0
}
