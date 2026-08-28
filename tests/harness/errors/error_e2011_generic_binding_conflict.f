//! TEST: generics_conflicting_bindings_error
//! COMPILE-ERROR: E2011

// `1` is constrained to the numeric kinds, so binding `T` to `bool` from the second argument makes
// the candidate fail to unify and the call has no overload left to pick. The narrower "T got i32
// and bool" reading is not reachable: conflicting bindings from two CONCRETE arguments are accepted
// today (see docs/known-issues.md), so the literal is what rejects this call.
pub fn same(a: $T, b: T) T {
    return a
}

pub fn main() i32 {
    let v: i32 = same(1, true)
    return v
}
