// Result type for error handling

import std.test

// Result(T, E) - a type representing either success (Ok) or failure (Err)
// T is the success value type, E is the error value type
pub enum Result(T, E) {
    Ok(T)
    Err(E)
}

// Check if the result is Ok
pub fn is_ok(self: Result($T, $E)) bool {
    return self match {
        Ok(_) => true,
        Err(_) => false
    }
}

// Check if the result is Err
pub fn is_err(self: Result($T, $E)) bool {
    return self match {
        Ok(_) => false,
        Err(_) => true
    }
}

// Unwrap the Ok value, panic if Err
pub fn unwrap(self: Result($T, $E)) T {
    return self match {
        Ok(value) => value,
        Err(_) => {
            panic("called unwrap on an Err value")
            // unreachable but needed for type checker
            const fake: T // zero init
            fake
        }
    }
}

// Unwrap the Ok value, or return a default if Err
pub fn unwrap_or(self: Result($T, $E), default: T) T {
    return self match {
        Ok(value) => value,
        Err(_) => default
    }
}

// Unwrap the Err value, panic if Ok
pub fn unwrap_err(self: Result($T, $E)) E {
    return self match {
        Ok(_) => {
            panic("called unwrap_err on an Ok value")
            // unreachable but needed for type checker
            const fake: E // zero init
            fake
        },
        Err(error) => error
    }
}

// =============================================================================
// Test Assertions for Result
// =============================================================================

// Assert that a Result is Ok, panic with message if Err
pub fn assert_ok(r: Result($T, $E), msg: String) {
    if (is_err(r)) {
        panic(msg)
    }
}

// Assert that a Result is Err, panic with message if Ok
pub fn assert_err(r: Result($T, $E), msg: String) {
    if (is_ok(r)) {
        panic(msg)
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Result.Ok construction and is_ok" {
    let r: Result(i32, i32) = Result.Ok(42)
    assert_true(is_ok(r), "Ok should return true for is_ok")
    assert_true(is_err(r) == false, "Ok should return false for is_err")
}

test "Result.Err construction and is_err" {
    let r: Result(i32, i32) = Result.Err(99)
    assert_true(is_err(r), "Err should return true for is_err")
    assert_true(is_ok(r) == false, "Err should return false for is_ok")
}

test "unwrap_or returns value on Ok" {
    let r: Result(i32, i32) = Result.Ok(10)
    let value = unwrap_or(r, 0)
    assert_eq(value, 10, "unwrap_or on Ok should return the Ok value")
}

test "unwrap_or returns default on Err" {
    let r: Result(i32, i32) = Result.Err(99)
    let value = unwrap_or(r, 42)
    assert_eq(value, 42, "unwrap_or on Err should return the default")
}

test "unwrap returns value on Ok" {
    let r: Result(i32, i32) = Result.Ok(123)
    let value = unwrap(r)
    assert_eq(value, 123, "unwrap on Ok should return the value")
}

test "unwrap_err returns error on Err" {
    let r: Result(i32, i32) = Result.Err(404)
    let err = unwrap_err(r)
    assert_eq(err, 404, "unwrap_err on Err should return the error")
}
