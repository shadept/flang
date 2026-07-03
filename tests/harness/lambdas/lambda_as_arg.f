//! TEST: lambda_as_arg
//! EXIT: 42

// Test passing a lambda directly to a higher-order function

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply(fn(x: i32) i32 { x * 2 }, 21)
}
