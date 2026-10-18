//! TEST: coalesce_releases_residual
//! EXPECT: 5
//! EXPECT: 0
//! EXPECT: 1

// `??` owns the residual it drops: an owned error is released before the fallback runs.

import std.io.print
import std.result

pub type Message = struct {
    owned code: i32
}

let released: i32 = 0

pub fn deinit(self: move Message) {
    released = released + 1
}

fn lookup(found: bool) Result(i32, Message) {
    if found {
        return Ok(5)
    }
    return Err(Message { code = 1 })
}

pub fn main() i32 {
    println(lookup(true) ?? 0)
    println(lookup(false) ?? 0)
    println(released)
    return 0
}
