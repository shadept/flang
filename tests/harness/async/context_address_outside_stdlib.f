//! TEST: context_address_outside_stdlib
//! COMPILE-ERROR: E2149

// The current context's address belongs to the standard library's coroutine runtime (RFC-005 D12);
// a program asking for it gets E2149, as for any other use of the context as a value.

import std.runtime.coro

pub fn main() i32 {
    const p: &u8 = context_address()
    return 0
}
