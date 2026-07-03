//! TEST: function_parameters_multiple
//! EXIT: 42

pub fn subtract(a: i32, b: i32) i32 {
    return a - b
}

pub fn addThree(a: i32, b: i32, c: i32) i32 {
    return a + b + c
}

pub fn main() i32 {
    let x: i32 = subtract(50, 8)
    let y: i32 = addThree(10, 20, 12)
    return x
}
