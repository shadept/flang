//! TEST: error_e2104_bare_generic_alias
//! COMPILE-ERROR: E2104

// A generic alias passes no arguments when named bare, and a body naming a generic type passes it
// all of its own (RFC-047).
type Box(T) = struct {
    v: T
}
type Shelf(T) = Box(T)
type Crate = Box // error[E2104]

fn take(s: Shelf) i32 { // error[E2104]
    return 0
}

pub fn main() i32 {
    const n: usize = size_of(Shelf) // error[E2104]
    return n as i32
}
