//! TEST: copyable_receiver_by_value
//! EXIT: 3

import std.char
import std.string

// A copy of a copyable value is unchecked, so a by-value receiver is not a
// consuming site and the value-mode UFCS chains keep working.
pub fn main() i32 {
    let s = "  ab  "
    let t = s.trim()
    if t.len != 2 {
        return 1
    }
    let c = 55u8
    if !c.is_digit() {
        return 2
    }
    return 3
}
