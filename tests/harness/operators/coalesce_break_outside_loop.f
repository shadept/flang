//! TEST: coalesce_break_outside_loop
//! COMPILE-ERROR: E1006
//! EXIT: 1

// `break` on the right of `??` follows the statement's rules: it needs an enclosing loop.

import std.option

pub fn main() i32 {
    let o: i32? = null
    let v: i32 = o ?? break
    return v
}
