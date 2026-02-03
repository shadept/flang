//! TEST: append_zero
//! EXIT: 0
//! STDOUT: 0

import core.string
import core.io
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(null)
    sb.append(0i32)
    println(sb.as_view())
    sb.deinit()
    return 0
}
