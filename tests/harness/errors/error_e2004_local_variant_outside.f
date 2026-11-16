//! TEST: error_e2004_local_variant_outside
//! COMPILE-ERROR: E2004

// RFC-046: a local enum's bare variant does not resolve in another function.
fn other() i32 {
    const e = Accepted(1) // error[E2004]
    return 0
}

pub fn main() i32 {
    type Event = enum {
        Accepted(i32)
        Stop
    }
    const e: Event = Stop
    return other()
}
