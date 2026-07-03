//! TEST: import_helper_leaker_outer
//! SKIP: helper module for transitive_leak_regression — not run directly

import _leaker_inner

pub fn outer_value() i32 {
    return leaked_value() + 1
}
