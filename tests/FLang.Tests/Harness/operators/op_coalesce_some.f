//! TEST: op_coalesce_some
//! EXIT: 10

// Test null-coalescing operator when Option has a value

import std.option

pub fn main() i32 {
    // Test with Some value - should return inner value, not fallback
    let a: i32? = 10
    let fallback: i32 = 99
    let result: i32 = a ?? fallback
    return result
}
