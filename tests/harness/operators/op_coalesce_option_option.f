//! TEST: op_coalesce_option_option
//! EXIT: 20

// Test null-coalescing operator with Option(T) ?? Option(T) -> Option(T)

import std.option

pub fn main() i32 {
    // Test Option ?? Option - first is null, use second
    let a: i32? = null
    let b: i32? = 20

    let result: i32? = a ?? b
    return unwrap_or(result, 0)
}
