//! TEST: interp_quotes_in_segment
//! EXIT: 0
//! STDOUT: say "hi"

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let msg = $"say \"hi\""
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
