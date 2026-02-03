//! TEST: append_u64
//! EXIT: 0
//! STDOUT: 18446744073709551615

import core.string
import core.io
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(null)
    sb.append(18446744073709551615u64)
    println(sb.as_view())
    sb.deinit()
    return 0
}
