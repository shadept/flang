//! TEST: generics_conflicting_bindings_error
//! COMPILE-ERROR: E2102

pub fn same(a: $T, b: T) T {
    return a
}

pub fn main() i32 {
    // Conflicting bindings for T: a is i32, b is bool
    let v: i32 = same(1, true)
    return v
}
