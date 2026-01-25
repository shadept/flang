//! TEST: result_match_basic
//! EXIT: 25

import std.result

pub fn main() i32 {
    let ok_result: Result(i32, i32) = Result.Ok(10)
    let err_result: Result(i32, i32) = Result.Err(5)

    // Match on Ok
    let v1 = ok_result match {
        Ok(x) => x,
        Err(_) => 0
    }

    // Match on Err
    let v2 = err_result match {
        Ok(_) => 0,
        Err(e) => e
    }

    // Match with computation in arm
    let v3 = ok_result match {
        Ok(x) => x,
        Err(e) => e
    }

    // v1=10, v2=5, v3=10 => 25
    return v1 + v2 + v3
}
