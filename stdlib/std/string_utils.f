// String utilities that depend on collections (List).
// Separated from std.string to avoid circular import issues.

import std.list
import std.string
import std.test

// Split a string by a byte delimiter. Returns a List of non-owning String views.
// max controls the maximum number of splits: -1 = unlimited.
// split("a,b,c", b',')    → ["a", "b", "c"]
// split("a,b,c", b',', 1) → ["a", "b,c"]
pub fn split(s: String, delimiter: u8, max: i32 = -1) List(String) {
    let result = list(String)
    let start: usize = 0
    let splits: i32 = 0

    for i in 0..s.len {
        if s[i] == delimiter and (max < 0 or splits < max) {
            const part = s[start..i]
            result.push(part as String)
            start = i + 1
            splits = splits + 1
        }
    }

    const tail = s[start..s.len]
    result.push(tail as String)
    return result.*
}

test "split basic" {
    let parts = split("a,b,c", b',')
    defer parts.deinit()

    assert_eq(parts.len, 3usize, "should have 3 parts")
    assert_eq(parts[0], "a", "first part")
    assert_eq(parts[1], "b", "second part")
    assert_eq(parts[2], "c", "third part")
}

test "split with max" {
    let parts = split("a,b,c,d", b',', 1)
    defer parts.deinit()

    assert_eq(parts.len, 2usize, "should have 2 parts")
    assert_eq(parts[0], "a", "first part")
    assert_eq(parts[1], "b,c,d", "remainder")
}

test "split no delimiter" {
    let parts = split("hello", b',')
    defer parts.deinit()

    assert_eq(parts.len, 1usize, "should have 1 part")
    assert_eq(parts[0], "hello", "whole string")
}

test "split empty segments" {
    let parts = split("a,,b", b',')
    defer parts.deinit()

    assert_eq(parts.len, 3usize, "should have 3 parts")
    assert_eq(parts[0], "a", "first")
    assert_eq(parts[1], "", "empty middle")
    assert_eq(parts[2], "b", "last")
}

test "partition basic" {
    const result = partition("key=value", b'=')
    assert_eq(result.0, "key", "before")
    assert_eq(result.1, "value", "after")
}

test "partition not found" {
    const result = partition("hello", b'=')
    assert_eq(result.0, "hello", "whole string")
    assert_eq(result.1, "", "empty after")
}

test "partition first occurrence" {
    const result = partition("a=b=c", b'=')
    assert_eq(result.0, "a", "before first =")
    assert_eq(result.1, "b=c", "after first =")
}
