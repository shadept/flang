//! TEST: defer_sb_then_return_to_string
//! EXIT: 5

// `defer sb.deinit()` followed by `return sb.to_string()`: the return
// expression evaluates first (to_string transfers the buffer and zeroes
// the builder), then the deferred deinit fires and finds cap=0 - no-op.
// Caller receives an OwnedString with len=5 ("hello").

import std.string
import std.string_builder

fn build() OwnedString {
    let sb = string_builder(8)
    sb.append("hello")
    defer sb.deinit()
    return sb.to_string()
}

pub fn main() i32 {
    let s = build()
    let n = s.len as i32
    s.deinit()
    return n
}
