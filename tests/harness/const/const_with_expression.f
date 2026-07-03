//! TEST: const_with_expression
//! EXIT: 30
pub fn main() i32 {
    const a: i32 = 10
    const b: i32 = 20
    const c: i32 = a + b
    return c
}
