//! TEST: error_e2154_arrowless_arity
//! COMPILE-ERROR: E2154

// A lambda without `=>` takes at most one parameter (`it`); two need names.
fn combine(a: i32, b: i32, f: fn(i32, i32) i32) i32 {
    return f(a, b)
}

pub fn main() i32 {
    return combine(1, 2) { it }
}
