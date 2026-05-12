//! TEST: defer_then_return_reads_owned
//! EXIT: 5
//! SKIP: defer fires before return-expression evaluates — see docs/known-issues.md ("defer x.deinit() + Return Expression Reading x")

// `defer s.deinit()` followed by a return expression that reads any
// field/method of `s` observes the post-deinit zeroed state. Same root
// cause as the `defer sb.deinit()` + `return sb.to_string()` zero-
// length case — reproduced through `OwnedString.as_view()` instead of
// `StringBuilder.to_string()`.
//
// Workaround in current code: drop the `defer` and call `deinit()`
// explicitly after the return value has been materialised.

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
