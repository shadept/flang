//! TEST: deque_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.collections.deque

// A deque owns its ring buffer, as a list owns its array.
pub fn main() i32 {
    let a: Deque(i32) = deque(4)
    a.push_back(1)
    let b = a // error E2124
    b.deinit()
    return 0
}
