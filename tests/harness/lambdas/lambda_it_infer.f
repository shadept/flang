//! TEST: lambda_it_infer
//! EXIT: 42

// RFC-039: `it` and named parameters take their types from the stdlib callback bounds.

import std.collections.list
import std.option
import std.sort

pub fn main() i32 {
    let xs = list(4)
    xs.push(3i32)
    xs.push(1i32)
    xs.push(2i32)
    const s = xs.as_slice()
    const total = s.fold(0i32) { acc, x => acc + x }
    const found = s.find { it == 1 } ?? 0
    xs.as_slice().sort_by { 0 - it }
    const tripled = Some(5i32)
        .map { it * 3 }
        .unwrap()
    if (s.any { it > 2 }) and (s.all { it > 0 }) {
        return total + found + xs[0] + tripled + 17
    }
    return 0
}
