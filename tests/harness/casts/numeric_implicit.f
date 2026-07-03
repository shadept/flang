//! TEST: numeric_implicit
//! EXIT: 123

pub fn take(n: usize) usize {
    return n
}

pub fn main() i32 {
    let b: u8 = 123
    let x: usize = take(b) // implicit integer cast u8 -> usize
    return x as i32
}
