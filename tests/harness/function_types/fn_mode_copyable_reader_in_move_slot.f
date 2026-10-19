//! TEST: fn_mode_copyable_reader_in_move_slot
//! EXIT: 0

// A function reading a copyable parameter fills a `move` slot: the value handed over needs no
// release (RFC-037).

type Code = enum {
    NotFound
    Denied
}

fn number(c: Code) i32 {
    return c match {
        NotFound => 2
        Denied => 13
    }
}

fn hand_over(c: move Code, f: fn(move Code) i32) i32 {
    return f(c)
}

pub fn main() i32 {
    const via_fn: i32 = hand_over(Code.Denied, number)
    const via_lambda: i32 = hand_over(Code.NotFound, { c: Code => number(c) })
    return via_fn + via_lambda - 15
}
