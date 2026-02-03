//! TEST: append_octal
//! EXIT: 0
//! STDOUT: 17

import core.string
import core.io
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(null)
    sb.append(15u32, "o")
    println(sb.as_view())
    sb.deinit()
    return 0
}
