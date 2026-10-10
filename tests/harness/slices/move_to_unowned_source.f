//! TEST: move_to_unowned_source
//! COMPILE-ERROR: E2125
//! EXIT: 1

import std.collections.list
import std.string

// Outside `List`'s module its buffer is not this module's storage: moving owners out of it would
// leave the list holding them too.
pub fn main() i32 {
    let a: List(OwnedString) = list(2)
    a.push(from_view("x"))
    a.push(from_view("y"))
    move_to(a.as_slice()[1..2], a.as_slice()[0..1]) // error E2125
    a.deinit()
    return 0
}
