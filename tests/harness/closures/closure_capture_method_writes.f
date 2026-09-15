//! TEST: closure_capture_method_writes
//! EXIT: 2

import std.collections.list

// A `&self` method on a captured name mutates the outer value, not a copy of its header.
pub fn main() i32 {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    let add = fn(v: i32) { xs.push(v) }
    add(1)
    add(2)
    return xs.len as i32
}
