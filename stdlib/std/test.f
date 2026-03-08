// Testing utilities for FLang
// Part of Milestone 16: Test Framework

import std.list
import std.string_builder

// Assert that a condition is true, panic with message if false
pub fn assert_true(condition: bool, msg: String) {
    if (condition == false) {
        panic(msg)
    }
}

// Assert that two values are equal
// NOTE: Uses == operator, so types must support equality comparison
pub fn assert_eq(a: $T, b: T, msg: String) {
    let equal: bool = a == b
    if (equal == false) {
        panic(msg)
    }
}

// Assert that two lists have the same elements in the same order.
// Uses == on each element pair.
pub fn assert_seq_eq(a: List($T), b: List(T), msg: String) {
    if a.len != b.len {
        let sb = string_builder(64)
        sb.append(msg)
        sb.append(": length mismatch (")
        sb.append(a.len as i64)
        sb.append(" vs ")
        sb.append(b.len as i64)
        sb.append(")")
        panic(sb.as_view())
    }
    for i in 0..a.len {
        let eq: bool = a[i] == b[i]
        if eq == false {
            let sb = string_builder(64)
            sb.append(msg)
            sb.append(": element mismatch at index ")
            sb.append(i as i64)
            panic(sb.as_view())
        }
    }
}

// Assert that two lists have the same elements regardless of order.
// Uses == on elements. O(n^2) — intended for small test collections.
pub fn assert_set_eq(a: List($T), b: List(T), msg: String) {
    if a.len != b.len {
        let sb = string_builder(64)
        sb.append(msg)
        sb.append(": length mismatch (")
        sb.append(a.len as i64)
        sb.append(" vs ")
        sb.append(b.len as i64)
        sb.append(")")
        panic(sb.as_view())
    }
    // Check every element in a exists in b
    for i in 0..a.len {
        let found = false
        for j in 0..b.len {
            let eq: bool = a[i] == b[j]
            if eq {
                found = true
                break
            }
        }
        if found == false {
            let sb = string_builder(64)
            sb.append(msg)
            sb.append(": element at index ")
            sb.append(i as i64)
            sb.append(" in first not found in second")
            panic(sb.as_view())
        }
    }
    // Check every element in b exists in a
    for i in 0..b.len {
        let found = false
        for j in 0..a.len {
            let eq: bool = b[i] == a[j]
            if eq {
                found = true
                break
            }
        }
        if found == false {
            let sb = string_builder(64)
            sb.append(msg)
            sb.append(": element at index ")
            sb.append(i as i64)
            sb.append(" in second not found in first")
            panic(sb.as_view())
        }
    }
}

// NOTE: assert_ok and assert_err are in std/result.f to avoid circular imports
