//! TEST: coalesce_consumes_kept_operand
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.option
import std.string

// `o ?? d` hands out `o`'s payload when the result is kept, so `o` is consumed.
pub fn main() i32 {
    let o: OwnedString? = Some(from_view("x"))
    let s = o ?? from_view("")
    s.deinit()
    o.deinit() // error E2123
    return 0
}
