//! TEST: copy_to_requires_copyable
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.collections.list
import std.string

// A bitwise duplicate of an owning element would own its buffer twice.
pub fn main() i32 {
    let a: List(OwnedString) = list(1)
    a.push(from_view("x"))
    let b: List(OwnedString) = list(1)
    b.push(from_view("y"))
    copy_to(a.as_slice(), b.as_slice()) // error E2134
    a.deinit()
    b.deinit()
    return 0
}
