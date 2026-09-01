// Result type for error handling

import std.option
import std.test

// Result(T, E) - a type representing either success (Ok) or failure (Err) T is the success value
// type, E is the error value type
pub type Result = enum(T, E) {
    Ok(T)
    Err(E)
}

// `?` on Result(T, E) works inside any fn returning Result(U, E): success type can differ, error
// type must match.
pub fn op_try(self: Result($T, $E)) TryResult(T, Result($U, E)) {
    return self match {
        Ok(v) => TryResult.Continue(v)
        Err(e) => TryResult.Return(Err(e))
    }
}

// Read-only, so the receiver is a reference: a by-value receiver of a non-copyable type has no
// receiver form at all (RFC-028), and `r.is_ok()` has to keep working for every payload.
pub fn is_ok(self: &Result($T, $E)) bool {
    return self.* match {
        Ok(_) => true
        Err(_) => false
    }
}

pub fn is_err(self: &Result($T, $E)) bool {
    return self.* match {
        Ok(_) => false
        Err(_) => true
    }
}

pub fn ok(self: Result($T, $E)) T? {
    return self match {
        Ok(v) => Some(v)
        Err(_) => None
    }
}

// The error as an optional, mirroring `ok`.
pub fn err(self: Result($T, $E)) E? {
    return self match {
        Ok(_) => None
        Err(e) => Some(e)
    }
}

// Apply `f` to an Ok value, leaving `Err` untouched. Transforms what a result holds without
// unwrapping and re-wrapping; `f` never runs on `Err`. When `f` itself returns a Result, use
// `and_then` so the result does not nest.
pub fn map(self: Result($T, $E), f: $F) Result($U, E) {
    return self match {
        Ok(v) => Ok(f(v))
        Err(e) => Err(e)
    }
}

// Apply `f` to an Err value, leaving `Ok` untouched. This is how a layer translates a lower layer's
// error into its own:
//
//     const raw = raw_dir_open(path).map_err(to_dir_error)?
//
// which is the whole point - `?` requires the error types to match, and without `map_err` every
// call site has to spell out an is_err / unwrap_err / re-wrap dance instead.
pub fn map_err(self: Result($T, $E), f: $F) Result(T, $U) {
    return self match {
        Ok(v) => Ok(v)
        Err(e) => Err(f(e))
    }
}

// `map` for a function that itself yields a Result, flattening the result. Chains a fallible step
// onto a fallible one; passing such a function to `map` would give `Result(Result(U, E), E)`. `Err`
// short-circuits and `f` never runs.
pub fn and_then(self: Result($T, $E), f: $F) Result($U, E) {
    return self match {
        Ok(v) => f(v)
        Err(e) => Err(e)
    }
}

pub fn except(self: Result($T, $E), msg: String) T {
    return self match {
        Ok(value) => value
        Err(_) => panic(msg)
    }
}

pub fn expect_err(self: Result($T, $E), msg: String) E {
    return self match {
        Ok(_) => panic(msg)
        Err(error) => error
    }
}

// Unwrap the Ok value, panic if Err
pub fn unwrap(self: Result($T, $E)) T {
    return self match {
        Ok(value) => value
        Err(_) => panic("called unwrap on an Err value")
    }
}

// Unwrap the Ok value, or return a default if Err
pub fn unwrap_or(self: Result($T, $E), default: T) T {
    return self match {
        Ok(value) => value
        Err(_) => default
    }
}

// Unwrap the Err value, panic if Ok
pub fn unwrap_err(self: Result($T, $E)) E {
    return self match {
        Ok(_) => panic("called unwrap_err on an Ok value")
        Err(error) => error
    }
}

// =============================================================================
// Test Assertions for Result
// =============================================================================

// Assert that a Result is Ok, panic with message if Err
pub fn assert_ok(r: Result($T, $E), msg: String) {
    if (r.is_err()) {
        panic(msg)
    }
}

// Assert that a Result is Err, panic with message if Ok
pub fn assert_err(r: Result($T, $E), msg: String) {
    if (r.is_ok()) {
        panic(msg)
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Result.Ok construction and is_ok" {
    let r: Result(i32, i32) = Result.Ok(42)
    assert_true(r.is_ok(), "Ok should return true for is_ok")
    assert_true(r.is_err() == false, "Ok should return false for is_err")
}

test "Result.Err construction and is_err" {
    let r: Result(i32, i32) = Result.Err(99)
    assert_true(r.is_err(), "Err should return true for is_err")
    assert_true(r.is_ok() == false, "Err should return false for is_ok")
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

test "map transforms an Ok and passes an Err through" {
    const doubled: Result(i32, String) = Ok(21).map(fn(v: i32) i32 { return v * 2 })
    assert_eq(doubled.unwrap(), 42, "Ok is mapped")

    const failed: Result(i32, String) = Err("nope")
    const still: Result(i32, String) = failed.map(fn(v: i32) i32 { return v * 2 })
    assert_true(still.is_err(), "Err passes through")
    assert_eq(still.unwrap_err(), "nope", "error is unchanged")
}

test "map_err translates an Err and leaves an Ok alone" {
    const failed: Result(i32, i32) = Err(2)
    const translated: Result(i32, String) = failed.map_err(fn(e: i32) String { return "code" })
    assert_true(translated.is_err(), "still an error")
    assert_eq(translated.unwrap_err(), "code", "error is translated")

    const fine: Result(i32, i32) = Ok(7)
    const untouched: Result(i32, String) = fine.map_err(fn(e: i32) String { return "code" })
    assert_eq(untouched.unwrap(), 7, "Ok is untouched")
}

test "and_then chains a fallible step without nesting" {
    const ok: Result(i32, String) = Ok(4)
    const chained: Result(i32, String) = ok.and_then(fn(v: i32) Result(i32,
            String) { return Ok(v + 1) })
    assert_eq(chained.unwrap(), 5, "chained through")

    const bailed: Result(i32, String) = ok.and_then(fn(v: i32) Result(i32,
            String) { return Err("bail") })
    assert_true(bailed.is_err(), "inner failure surfaces")
}

test "err mirrors ok" {
    const good: Result(i32, String) = Ok(1)
    const bad: Result(i32, String) = Err("x")
    assert_true(good.err().is_none(), "Ok has no error")
    assert_true(bad.err().is_some(), "Err has one")
    assert_eq(bad.err().unwrap(), "x", "and it is the error")
}
