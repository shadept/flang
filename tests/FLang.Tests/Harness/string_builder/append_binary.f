//! TEST: append_binary
//! EXIT: 0
//! STDOUT: 1010

import core.string
import core.io
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(null)
    sb.append(10u32, "b")
    println(sb.as_view())
    sb.deinit()
    return 0
}
