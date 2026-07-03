//! TEST: interp_unicode_escape
//! EXIT: 0
//! STDOUT: A-B

// `\u` escapes are decoded in segments just like in normal string literals.
// 0x41 = 'A', 0x42 = 'B'.

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let x = "-"
    let msg = $"\u0041{x}\u0042"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
