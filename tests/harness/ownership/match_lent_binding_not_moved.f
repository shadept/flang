//! TEST: match_lent_binding_not_moved
//! COMPILE-ERROR: E2131
//! EXIT: 1

import std.option
import std.string

// `v` names part of `o`, which the function only reads: handing it out would leave the caller a
// second owner. Taking it out needs `o: move Option(OwnedString)`.
fn take(o: Option(OwnedString)) OwnedString {
    return o match {
        Some(v) => v // error E2131
        None => from_view("")
    }
}

pub fn main() i32 {
    let o: OwnedString? = Some(from_view("x"))
    let s = take(o)
    s.deinit()
    o.deinit()
    return 0
}
