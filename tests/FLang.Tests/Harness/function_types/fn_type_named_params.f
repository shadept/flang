//! TEST: fn_type_named_params
//! EXIT: 30

// Test function types with optional named parameters for documentation
// Both fn(i32, i32) i32 and fn(a: i32, b: i32) i32 should work

fn add(a: i32, b: i32) i32 {
    return a + b
}

fn multiply(x: i32, y: i32) i32 {
    return x * y
}

// Named parameters in function type (for documentation)
fn apply_named(f: fn(left: i32, right: i32) i32, a: i32, b: i32) i32 {
    return f(a, b)
}

// Anonymous parameters in function type (original syntax)
fn apply_anon(f: fn(i32, i32) i32, a: i32, b: i32) i32 {
    return f(a, b)
}

pub fn main() i32 {
    let sum = apply_named(add, 10, 5)      // 15
    let product = apply_anon(multiply, 3, 5) // 15
    return sum + product                    // 30
}
