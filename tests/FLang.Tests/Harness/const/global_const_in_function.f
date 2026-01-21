//! TEST: global_const_in_function
//! EXIT: 50

const MULTIPLIER: i32 = 5

fn multiply(x: i32) i32 {
    return x * MULTIPLIER
}

pub fn main() i32 {
    return multiply(10)
}
