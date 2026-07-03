//! TEST: default_args_basic
//! EXIT: 15

fn add(a: i32, b: i32 = 10) i32 {
    return a + b
}

pub fn main() i32 {
    let r1 = add(5)
    let r2 = add(5, 20)
    // r1 = 15, r2 = 25
    return r1
}
