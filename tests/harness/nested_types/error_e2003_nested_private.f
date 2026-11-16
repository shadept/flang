//! TEST: error_e2003_nested_private
//! COMPILE-ERROR: E2003

// RFC-046: a nested type without `pub` is visible only in its own module, and an owner declaring no
// such type names nothing.
import _nested_lib

pub fn main() i32 {
    const h: Pub.Hidden = Pub.Hidden { x = 1 } // error[E2003]
    const z: usize = size_of(Pub.Hidden) // error[E2003]
    const m: Pub.Missing = Pub.Open { x = 2 } // error[E2003]
    return 0
}
