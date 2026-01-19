//! TEST: op_coalesce_basic
//! EXIT: 42

// Test basic null-coalescing operator (Option(T) ?? T -> T)

import std.option

pub fn main() i32 {
    // Test with null option - should return fallback
    let a: i32? = null
    let fallback: i32 = 42
    let result1: i32 = a ?? fallback
    return result1
}
