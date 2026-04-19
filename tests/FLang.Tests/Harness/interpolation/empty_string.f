//! TEST: interp_empty_string
//! EXIT: 0

import std.string_builder
import std.string

pub fn main() i32 {
    let msg = $""
    defer msg.deinit()

    if msg.len != 0 { return 1 }
    return 0
}
