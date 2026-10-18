//! TEST: error_e1053_fn_lambda_removed
//! COMPILE-ERROR: E1053

// The `fn(params) R { body }` lambda form was removed by RFC-039.
fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply(fn(x: i32) i32 { x * 2 }, 21)
}
