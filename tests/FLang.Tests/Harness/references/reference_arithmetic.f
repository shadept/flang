//! TEST: reference_arithmetic
//! EXIT: 15

pub fn addValues(a: &i32, b: &i32) i32 {
    return a.* + b.*
}

pub fn main() i32 {
    let x: i32 = 10
    let y: i32 = 5
    return addValues(&x, &y)
}
