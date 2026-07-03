//! TEST: result_basic
//! EXIT: 42

import std.result

pub fn main() i32 {
    let ok_result: Result(i32, i32) = Result.Ok(10)
    let err_result: Result(i32, i32) = Result.Err(99)

    // Test is_ok / is_err
    let ok_check: i32 = 0
    if (is_ok(ok_result)) {
        ok_check = 1
    }
    let err_check: i32 = 0
    if (is_err(err_result)) {
        err_check = 1
    }

    // Test unwrap_or
    let v1 = unwrap_or(ok_result, 0)   // should be 10
    let v2 = unwrap_or(err_result, 30) // should be 30

    // Return sum: 1 + 1 + 10 + 30 = 42
    return ok_check + err_check + v1 + v2
}
