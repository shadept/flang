//! TEST: context_cross_module
//! EXIT: 0

// A `pub` field is read and rebound from an importing module, and the declaring module's own reads
// see the rebind. A private field is the declaring module's alone, but still part of the one
// context its functions run under.

import _ctx_lib

pub fn main() i32 {
    if context.level != 5 {
        return 1
    }
    const seen: i32 = context(level = 8i32) { level_here() }
    if seen != 8 {
        return 2
    }
    if secret_here() != 9 {
        return 3
    }
    return 0
}
