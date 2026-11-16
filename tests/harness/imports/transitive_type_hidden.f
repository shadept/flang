//! TEST: transitive_type_hidden
//! COMPILE-ERROR: E2003

// SH-102: `_hidden_b` imports `_hidden_a`; this module imports only `_hidden_b`, so `HiddenBox` is
// not visible here.
import _hidden_b

pub fn main() i32 {
    const b: HiddenBox = .{ x = 1 } // error[E2003]
    return b.x
}
