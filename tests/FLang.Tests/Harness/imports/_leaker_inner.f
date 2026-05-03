//! TEST: import_helper_leaker_inner
//! SKIP: helper module for transitive_leak_regression — not run directly

pub fn leaked_value() i32 {
    return 99
}
