//! TEST: transitive_leak_regression
//! COMPILE-ERROR: E2004

// Regression test for the import-transitivity gap (RFC-013).
//
// Per spec.md §6, imports are non-transitive: importing _leaker_outer must NOT
// expose _leaker_inner's pub items. This test imports only _leaker_outer and
// then calls leaked_value() — defined in _leaker_inner. Must fail to resolve.

import _leaker_outer

pub fn main() i32 {
    return leaked_value()
}
