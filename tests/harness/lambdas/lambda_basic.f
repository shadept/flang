//! TEST: lambda_basic
//! EXIT: 42

// Test basic lambda with explicit parameter types and return type

fn apply(f: fn(i32, i32) i32, a: i32, b: i32) i32 {
    return f(a, b)
}

pub fn main() i32 {
    let add = fn(x: i32, y: i32) i32 { x + y }
    return add(20, 22)
}
