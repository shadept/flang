//! TEST: list_basic
//! SKIP: Blocked by compiler bug - generic struct field assignment via reference

// This test is blocked by a compiler bug. See docs/known-issues.md
// Once the bug is fixed, this test should EXIT: 15

import std.list
import std.option

pub fn main() i32 {
    let list: List(i32) = list_new()

    // Test push and len
    list.push(5)
    list.push(10)

    let len1: usize = list.len()
    if (len1 != 2) {
        return 1
    }

    // Test get
    let first: i32 = list.get(0)
    let second: i32 = list.get(1)

    // Test set
    list.set(0, 7)
    let updated: i32 = list.get(0)
    if (updated != 7) {
        return 2
    }

    // Test pop
    let popped: i32? = list.pop()
    let pop_val: i32 = unwrap_or(popped, 0)
    if (pop_val != 10) {
        return 3
    }

    let len2: usize = list.len()
    if (len2 != 1) {
        return 4
    }

    // Clean up
    list.deinit()

    // first(5) + second(10) = 15
    return first + second
}
