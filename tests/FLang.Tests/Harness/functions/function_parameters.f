//! TEST: function_parameters
//! EXIT: 15

pub fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn multiply(x: i32, y: i32) i32 {
    return x * y
}

pub fn main() i32 {
    let result1: i32 = add(10, 5)
    let result2: i32 = multiply(3, 5)
    return result1
}
