//! TEST: op_try_result_basic
//! EXIT: 0

import std.result

fn parse_pos(s: i32) Result(i32, i32) {
    if s < 0 { return Result.Err(s) }
    return Result.Ok(s)
}

fn sum_two(a: i32, b: i32) Result(i32, i32) {
    let av = parse_pos(a)?
    let bv = parse_pos(b)?
    return Result.Ok(av + bv)
}

pub fn main() i32 {
    let r1 = sum_two(3, 4)
    if is_err(r1) { return 1 }
    if unwrap(r1) != 7 { return 2 }

    let r2 = sum_two(3, -5)
    if is_ok(r2) { return 3 }
    if unwrap_err(r2) != -5 { return 4 }

    let r3 = sum_two(-1, 4)
    if is_ok(r3) { return 5 }
    if unwrap_err(r3) != -1 { return 6 }

    return 0
}
