//! TEST: default_args_multiple
//! EXIT: 6

fn compute(a: i32, b: i32 = 2, c: i32 = 3) i32 {
    return a + b + c
}

pub fn main() i32 {
    let r1 = compute(1)        // 1 + 2 + 3 = 6
    let r2 = compute(1, 10)    // 1 + 10 + 3 = 14
    let r3 = compute(1, 10, 20) // 1 + 10 + 20 = 31
    return r1
}
