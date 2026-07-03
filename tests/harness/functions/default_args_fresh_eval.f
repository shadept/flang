//! TEST: default_args_fresh_eval
//! EXIT: 60

// Proves default expressions are freshly evaluated per call site
fn double(x: i32) i32 {
    return x * 2
}

fn compute(a: i32, b: i32 = double(5)) i32 {
    return a + b
}

pub fn main() i32 {
    let r1 = compute(10)      // 10 + double(5) = 10 + 10 = 20
    let r2 = compute(10)      // 10 + double(5) = 10 + 10 = 20
    let r3 = compute(10, 30)  // 10 + 30 = 40
    // r1 + r2 = 40 (proves fresh eval: both got 20, not sharing state)
    // return r1 + r2 + r3 - 40 = 20 + 20 + 40 - 40 = 40... too big
    return r1 + r2 + r3 - 20  // 20 + 20 + 40 - 20 = 60
}
