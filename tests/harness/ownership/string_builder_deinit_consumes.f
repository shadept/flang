//! TEST: string_builder_deinit_consumes
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.string_builder

// `deinit` takes the builder: releasing it twice is a use after move, not a run-time no-op.
pub fn main() i32 {
    let sb = string_builder(8)
    sb.append("x")
    sb.deinit()
    sb.deinit() // error E2123
    return 0
}
