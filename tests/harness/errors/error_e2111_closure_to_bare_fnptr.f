//! TEST: error_e2111_closure_to_bare_fnptr
//! COMPILE-ERROR: E2111

// A capturing closure cannot silently coerce to a bare function-pointer type.
// Empty captures decay normally; non-empty captures are rejected with E2111.

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    let k = 7
    return apply(fn(x: i32) i32 { x * k }, 5)
}
