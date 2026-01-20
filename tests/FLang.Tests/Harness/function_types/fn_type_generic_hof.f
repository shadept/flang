//! TEST: fn_type_generic_hof
//! EXIT: 20

// Test generic higher-order function with function type parameter

fn double(x: i32) i32 {
    return x * 2
}

// Generic HOF: works with any type T where f: T -> T
fn apply_twice(f: fn($T) T, x: T) T {
    return f(f(x))
}

pub fn main() i32 {
    // apply_twice(double, 5) = double(double(5)) = double(10) = 20
    return apply_twice(double, 5)
}
