//! TEST: fn_type_no_coercion_error
//! COMPILE-ERROR: E2011

// Function types must match exactly - no coercion between i32 and i64

fn takes_i32(x: i32) i32 {
    return x
}

fn apply(f: fn(i64) i64, x: i64) i64 {
    return f(x)
}

pub fn main() i32 {
    // ERROR: takes_i32 is fn(i32) i32, not fn(i64) i64
    let result = apply(takes_i32, 10)
    return 0
}
