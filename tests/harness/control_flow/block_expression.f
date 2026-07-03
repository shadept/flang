//! TEST: block_expression_test
//! EXIT: 42
pub fn main() i32 {
    let x: i32 = {
        let temp: i32 = 40
        temp + 2
    }
    return x
}
