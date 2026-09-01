//! TEST: copyable_receiver_chain
//! EXIT: 3

import std.option

fn triple(v: i32) i32 {
    return v * 3
}

// Both hops take their receiver by value, and both payloads are copyable.
pub fn main() i32 {
    let some: Option(i32) = Some(1)
    return some.map(triple).unwrap_or(0)
}
