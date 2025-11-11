//! TEST: arithmetic_ops_test
//! EXIT: 72
pub fn main() i32 {
    let a: i32 = 10
    let b: i32 = 5
    let add: i32 = a + b
    let sub: i32 = a - b
    let mul: i32 = a * b
    let div: i32 = a / b
    let mod: i32 = a % b
    return add + sub + mul + div + mod
}
