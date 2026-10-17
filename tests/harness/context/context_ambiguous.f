//! TEST: context_ambiguous
//! COMPILE-ERROR: E2152
//! EXIT: 1

import _ctx_lib
import _ctx_other

pub fn main() i32 {
    return context.level // error E2152: both modules declare a visible `level`
}
