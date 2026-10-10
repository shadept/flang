//! TEST: path_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.path

// A path owns its buffer through the builder it holds.
pub fn main() i32 {
    let p = path("a/b")
    let q = p // error E2124
    q.deinit()
    return 0
}
