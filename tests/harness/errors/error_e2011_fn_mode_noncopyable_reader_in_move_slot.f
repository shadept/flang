//! TEST: error_e2011_fn_mode_noncopyable_reader_in_move_slot
//! COMPILE-ERROR: E2011
//! COMPILE-ERROR: E2002

// A function reading a non-copyable parameter does not fill a `move` slot: the caller hands the
// value over and the reader would never release it (RFC-037). The copyable mirror is
// `function_types/fn_mode_copyable_reader_in_move_slot.f`.

import std.string

type Code = enum {
    NotFound
    Denied(OwnedString)
}

fn number(c: Code) i32 {
    return c match {
        NotFound => 2
        Denied(_) => 13
    }
}

fn hand_over(c: move Code, f: fn(move Code) i32) i32 {
    return f(c)
}

pub fn main() i32 {
    const denied: Code = Code.Denied(from_view("no"))
    const via_fn: i32 = hand_over(denied, number)
    const via_lambda: i32 = hand_over(Code.NotFound, { c: Code => number(c) })
    return via_fn + via_lambda - 15
}
