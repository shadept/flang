//! TEST: string_builder_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.string_builder

// A builder owns its buffer: a second binding would free it twice.
pub fn main() i32 {
    let a = string_builder(8)
    a.append("x")
    let b = a // error E2124
    b.deinit()
    return 0
}
