//! TEST: named_args_mixed
//! EXIT: 30

fn calc(a: i32, b: i32, c: i32) i32 {
    return a * b + c
}

pub fn main() i32 {
    // First positional (a=5), then named (c=10, b=4)
    let r = calc(5, c = 10, b = 4)  // 5 * 4 + 10 = 30
    return r
}
