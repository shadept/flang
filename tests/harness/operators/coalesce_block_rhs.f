//! TEST: coalesce_block_rhs
//! EXPECT: oops
//! EXPECT: true
//! EXPECT: 2
//! EXPECT: fallback
//! EXPECT: 7
//! EXPECT: -1

// The right side of `??` is any match-arm body: a block that yields or leaves, or an `if`.

import std.io.print
import std.option
import std.result

fn get(o: i32?) Result(i32, String) {
    let v: i32 = o ?? {
        println("oops")
        return Err("oops")
    }
    return Ok(v + 1)
}

fn pick(o: i32?) i32 {
    let v: i32 = o ?? {
        println("fallback")
        7
    }
    return v
}

fn first(o: i32?, xs: i32[]) i32 {
    let v: i32 = o ?? if xs.len > 0 { xs[0] } else { return -1 }
    return v
}

pub fn main() i32 {
    println(get(null).is_err())
    println(get(Some(1)).unwrap())
    println(pick(null))
    let e: [i32; 0] = []
    println(first(null, e))
    return 0
}
