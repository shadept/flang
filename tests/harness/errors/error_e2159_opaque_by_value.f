//! TEST: error_e2159_opaque_by_value
//! COMPILE-ERROR: E2159

// An opaque C type has no storage FLang can see, so it never appears by value.

type Handle = #foreign struct {}

fn take(h: Handle) {}

pub fn main() i32 {
    return 0
}
