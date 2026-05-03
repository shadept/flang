//! TEST: op_try_result_cross_T
//! EXIT: 0

// `?` on `Result(T, E)` works inside any function returning `Result(U, E)`
// for the SAME `E` and any `U`. The success type can differ; the error
// type must still match because the `Err(e)` payload is propagated as-is.

import std.result

fn parse_pos(n: i32) Result(i32, String) {
    if n < 0 { return Err("negative") }
    return Ok(n)
}

// Caller returns Result((i32, i32), String) — different success type, same error.
fn parse_pair(a: i32, b: i32) Result((i32, i32), String) {
    let av = parse_pos(a)?
    let bv = parse_pos(b)?
    return Ok((av, bv))
}

pub fn main() i32 {
    let ok = parse_pair(3, 4) match {
        Ok(p) => p,
        Err(_) => return 1,
    }
    if ok.0 != 3 { return 2 }
    if ok.1 != 4 { return 3 }

    let bad = parse_pair(3, -1) match {
        Ok(_) => return 4,
        Err(_) => 0,
    }
    return bad
}
