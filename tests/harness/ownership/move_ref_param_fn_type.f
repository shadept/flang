//! TEST: move_ref_param_fn_type
//! COMPILE-ERROR: E2130
//! EXIT: 1

// Rule 5 holds in a function type and on a lambda parameter as on a declaration.
pub fn main() i32 {
    let n: i32 = 3
    let f: fn(move &i32) i32 = fn(v: move &i32) i32 { return v.* }
    return f(&n)
}
