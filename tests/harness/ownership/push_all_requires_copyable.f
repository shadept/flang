//! TEST: push_all_requires_copyable
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.collections.list
import std.string

// `push_all` copies its slice bitwise: an owning element would end up owned twice.
pub fn main() i32 {
    let a: List(OwnedString) = list(1)
    a.push(from_view("x"))
    let b: List(OwnedString) = list(1)
    b.push_all(a.as_slice()) // error E2134
    a.deinit()
    b.deinit()
    return 0
}
