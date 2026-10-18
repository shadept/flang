//! TEST: error_e2011_move_slot_noncopyable_reader
//! COMPILE-ERROR: E2011

// A function that only reads a non-copyable parameter cannot fill a `move` slot: the caller hands
// ownership over and nothing would release the value (RFC-037).

import std.string

fn len_of(s: OwnedString) usize {
    return s.len
}

fn take(s: move OwnedString, f: fn(move OwnedString) usize) usize {
    return f(s)
}

pub fn main() i32 {
    const s: OwnedString = from_view("owned")
    return take(s, len_of) as i32
}
