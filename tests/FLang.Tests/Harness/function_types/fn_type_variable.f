//! TEST: fn_type_variable
//! EXIT: 15

// Test storing a function in a variable

fn multiply_by_three(x: i32) i32 {
    return x * 3
}

pub fn main() i32 {
    let f: fn(i32) i32 = multiply_by_three
    return f(5)
}
