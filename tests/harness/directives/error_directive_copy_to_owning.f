//! TEST: error_directive_copy_to_owning
//! COMPILE-ERROR: E2999 copy_to needs copyable elements, OwnedString owns something

import std.collections.list
import std.string

// `copy_to` over an owning element type reaches the `#error` inside the instantiation; the report
// lands here, at the call, not in slice.f.
pub fn main() i32 {
    let src: List(OwnedString) = list(1)
    defer src.deinit()
    src.push(from_view("a"))
    let dest: List(OwnedString) = list(1)
    defer dest.deinit()
    dest.push(from_view("b"))
    const n = copy_to(src.as_slice(), dest.as_slice())
    return n as i32
}
