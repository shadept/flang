//! TEST: result_ufcs
//! EXIT: 52

import std.result

pub fn main() i32 {
    let ok_result: Result(i32, i32) = Result.Ok(10)
    let err_result: Result(i32, i32) = Result.Err(99)

    // Test UFCS: is_ok and is_err
    let ok_check: i32 = 0
    if (ok_result.is_ok()) {
        ok_check = 1
    }

    let err_check: i32 = 0
    if (err_result.is_err()) {
        err_check = 1
    }

    // Test UFCS: unwrap_or
    let v1 = ok_result.unwrap_or(0)   // should be 10
    let v2 = err_result.unwrap_or(40) // should be 40

    // Return sum: 1 + 1 + 10 + 40 = 52
    return ok_check + err_check + v1 + v2
}
