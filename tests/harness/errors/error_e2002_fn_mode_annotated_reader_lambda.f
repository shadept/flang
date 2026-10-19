//! TEST: error_e2002_fn_mode_annotated_reader_lambda
//! COMPILE-ERROR: E2002

// A lambda that declares a reading parameter of a non-copyable type does not fill a `move` slot;
// only an unannotated parameter takes the slot's mode (RFC-037).

import std.string

fn take(s: move OwnedString, f: fn(move OwnedString) usize) usize {
    return f(s)
}

pub fn main() i32 {
    const s: OwnedString = from_view("owned")
    return take(s, { x: OwnedString => x.len }) as i32
}
