//! TEST: drain_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.collections.list
import std.string

// A drain holds the right to take the elements: a copy would hand each one out twice.
pub fn main() i32 {
    let a: List(OwnedString) = list(1)
    a.push(from_view("x"))
    let d = a.drain()
    let d2 = d // error E2124
    for y in d2 {
        y.deinit()
    }
    a.deinit()
    return 0
}
