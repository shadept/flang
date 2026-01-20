//! TEST: fn_type_multiple_params
//! EXIT: 11

// Test function type with multiple parameters

fn add(a: i32, b: i32) i32 {
    return a + b
}

fn apply_binary(f: fn(i32, i32) i32, x: i32, y: i32) i32 {
    return f(x, y)
}

pub fn main() i32 {
    return apply_binary(add, 5, 6)
}
