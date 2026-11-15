//! TEST: context_address_outside_stdlib
//! COMPILE-ERROR: E2149

// A program module calling the context-address intrinsic gets E2149.

import std.runtime.coro

pub fn main() i32 {
    const p: &u8 = context_address()
    return 0
}
