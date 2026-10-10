//! TEST: coalesce_lent_operand
//! COMPILE-ERROR: E2131
//! EXIT: 1

import std.option
import std.string

// A parameter without `move` cannot give up its payload through `??`.
fn take(o: Option(OwnedString)) OwnedString {
    return o ?? from_view("") // error E2131
}

pub fn main() i32 {
    let o: OwnedString? = Some(from_view("x"))
    let s = take(o)
    s.deinit()
    o.deinit()
    return 0
}
