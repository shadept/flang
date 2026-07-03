//! TEST: fn_type_basic
//! EXIT: 42

// Test basic function type: passing a function as an argument

fn add_ten(x: i32) i32 {
    return x + 10
}

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    let result = apply(add_ten, 32)
    return result
}
