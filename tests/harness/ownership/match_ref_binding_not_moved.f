//! TEST: match_ref_binding_not_moved
//! COMPILE-ERROR: E2131
//! EXIT: 1

import std.option
import std.string

// Behind a reference the binding may be read and written, not moved out.
fn take(o: &Option(OwnedString)) OwnedString {
    return o.* match {
        Some(v) => v // error E2131
        None => from_view("")
    }
}

pub fn main() i32 {
    let o: OwnedString? = Some(from_view("x"))
    let s = take(&o)
    s.deinit()
    o.deinit()
    return 0
}
