//! TEST: lambda_infer_params
//! EXIT: 42

// Test lambda parameter type inference from expected function type

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    let f: fn(i32) i32 = fn(x) { x + 1 }
    return f(41)
}
