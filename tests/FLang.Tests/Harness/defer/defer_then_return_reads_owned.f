//! TEST: defer_then_return_reads_owned
//! EXIT: 5

// `defer s.deinit()` followed by a return expression that reads
// `s` is honoured: the return expression evaluates first, then the
// deferred call fires. Pins ordering against the regression where
// defers fired before the return-expression's operand evaluation
// (zero-length OwnedString observed in `as_view()`).

import std.string
import std.string_builder

fn make_hello() OwnedString {
    let sb = string_builder(8)
    sb.append("hello")
    return sb.to_string()
}

fn len_of(s: String) i32 {
    return s.len as i32
}

pub fn main() i32 {
    let s = make_hello()
    defer s.deinit()
    return len_of(s.as_view())
}
