//! TEST: append_bool
//! EXIT: 0
//! STDOUT: true false

import core.string
import core.io
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(null)
    sb.append(true)
    sb.append(" ")
    sb.append(false)
    println(sb.as_view())
    sb.deinit()
    return 0
}
