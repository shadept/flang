//! TEST: op_coalesce_chain
//! EXIT: 5

// Test chained null-coalescing operator with Option ?? Option

import std.option

pub fn main() i32 {
    // Test chaining: first two are null, third has value
    let a: i32? = null
    let b: i32? = null
    let c: i32? = 5

    // Right-associative: should evaluate as a ?? (b ?? c)
    // a ?? (b ?? c): both return Option(i32), result is Option(i32) = c = 5
    let result: i32? = a ?? b ?? c
    return unwrap_or(result, 0)
}
