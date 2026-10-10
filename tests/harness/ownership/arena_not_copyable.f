//! TEST: arena_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.allocator

// An arena owns its page chain; what it hands out are plain references into those pages.
pub fn main() i32 {
    let a = arena_allocator(global())
    let b = a // error E2124
    b.deinit()
    return 0
}
