//! TEST: interp_empty_string
//! EXIT: 0

import std.string
import std.string_builder

pub fn main() i32 {
    let msg = $""
    defer msg.deinit()

    if msg.view().len != 0 {
        return 1
    }
    return 0
}
