//! TEST: named_args_basic
//! EXIT: 7

fn sub(a: i32, b: i32) i32 {
    return a - b
}

pub fn main() i32 {
    let r = sub(b = 3, a = 10)  // 10 - 3 = 7
    return r
}
