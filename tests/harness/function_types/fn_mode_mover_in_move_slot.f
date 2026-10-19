//! TEST: fn_mode_mover_in_move_slot
//! EXIT: 0

// A function that takes its parameter by `move` fills a `move` slot: ownership passes from the
// caller through the slot to the callee, which releases it (RFC-037).

import std.string

fn consume(s: move OwnedString) usize {
    const n: usize = s.len
    s.deinit()
    return n
}

fn hand_over(s: move OwnedString, f: fn(move OwnedString) usize) usize {
    return f(s)
}

pub fn main() i32 {
    const s: OwnedString = from_view("owned")
    return hand_over(s, consume) as i32 - 5
}
