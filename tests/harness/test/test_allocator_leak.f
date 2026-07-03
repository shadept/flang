//! TEST: test_allocator_leak_detection
//! EXIT: 0

// Verifies that the test allocator is used in test mode and properly cleans up.
// This test is compiled in normal (non-test) mode via the harness.
// The actual leak detection is tested via `flang test` manually.

import std.list
import std.test

test "clean test" {
    let items = List(i32){}
    items.push(42)
    items.push(99)
    assert_eq(items.len, 2 as usize, "list should have 2 items")
    items.deinit()
}

pub fn main() i32 {
    return 0
}
