//! TEST: slot_param_core_only
//! COMPILE-ERROR: E2136
//! EXIT: 1

type Handle = struct {
    owned fd: i32
}

// `&move T` is the one mode that takes a value out of storage the caller keeps, so it is declared
// in `core` alone (`swap`, `replace`) and nowhere else.
fn steal(slot: &move Handle) Handle {
    return move slot.*
}

pub fn main() i32 {
    return 0
}
