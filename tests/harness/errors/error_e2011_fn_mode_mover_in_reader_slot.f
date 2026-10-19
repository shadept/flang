//! TEST: error_e2011_fn_mode_mover_in_reader_slot
//! COMPILE-ERROR: E2011

// A `move` parameter never fills a reading slot, even for a copyable type: the caller lends its
// own storage, which the callee would own and may write (RFC-037).

fn bump(x: move i32) i32 {
    x = x + 1
    return x
}

fn apply(x: i32, f: fn(i32) i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply(1i32, bump)
}
