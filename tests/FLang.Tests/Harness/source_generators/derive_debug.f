//! TEST: derive_debug
//! EXIT: 0

import std.derive
import std.string_builder

type Pair = struct {
    a: i32
    b: i32
}

#derive(Pair, debug)

pub fn main() i32 {
    let p = Pair { a = 10, b = 20 }
    let sb = string_builder()
    p.format(&sb, "")
    let s = sb.to_string()

    // Expected: "Pair { a = 10, b = 20, }"
    if s.len == 0 { return 1 }

    // Check the output matches
    if s.as_view() != "Pair { a = 10, b = 20, }" { return 2 }

    sb.deinit()
    s.deinit()
    return 0
}
