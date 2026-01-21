//! TEST: ufcs_with_args
//! EXIT: 23

// UFCS requires reference for first parameter
fn add(a: &i32, b: i32) i32 {
    return a.* + b
}

pub fn main() i32 {
    let x: i32 = 20
    // UFCS: x.add(3) -> add(&x, 3)
    return x.add(3)
}
