//! TEST: coalesce_result
//! EXPECT: 7
//! EXPECT: fallback
//! EXPECT: 0
//! EXPECT: -2

// `??` on a Result goes through `op_try`: the `Ok` payload, or the fallback - evaluated only then -
// with the error dropped.

import std.io.print
import std.result

fn parse(ok: bool) Result(i32, i32) {
    if ok {
        return Ok(7)
    }
    return Err(99)
}

fn fallback() i32 {
    println("fallback")
    return 0
}

fn checked(ok: bool) i32 {
    let v: i32 = parse(ok) ?? return -2
    return v
}

pub fn main() i32 {
    println(parse(true) ?? fallback())
    println(parse(false) ?? fallback())
    println(checked(false))
    return 0
}
