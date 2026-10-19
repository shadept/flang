//! TEST: fn_mode_lambda_inherits_move
//! EXIT: 0

// An unannotated lambda parameter takes the `move` of the slot it fills, so the body owns the value
// and may move it on (RFC-037).

import std.string

type Holder = struct {
    s: OwnedString
}

fn wrap(s: move OwnedString, f: fn(move OwnedString) Holder) Holder {
    return f(s)
}

pub fn main() i32 {
    const s: OwnedString = from_view("owned")
    const h: Holder = wrap(s) { Holder { s = move it } }
    const n: usize = h.s.len
    h.s.deinit()
    return n as i32 - 5
}
