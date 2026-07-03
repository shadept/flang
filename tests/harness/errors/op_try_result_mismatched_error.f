//! TEST: op_try_result_mismatched_error
//! COMPILE-ERROR: E2071
//! EXIT: 1

// `?` on `Result(_, E1)` inside a function returning `Result(_, E2)`
// with E1 != E2 must error: there is no implicit error-type conversion.
// Only the success type can vary across `?`.

import std.result

fn produces_string_err() Result(i32, String) { return Err("oops") }

fn caller() Result(i32, i32) {
    let v = produces_string_err()?   // String -> i32 error mismatch
    return Ok(v)
}

pub fn main() i32 {
    let r = caller()
    if r.is_err() { return 1 }
    return 0
}
