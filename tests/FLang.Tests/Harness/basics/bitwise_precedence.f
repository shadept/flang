//! TEST: bitwise_precedence
//! EXIT: 7
pub fn main() i32 {
    // Test that & binds tighter than |, and | binds tighter than logical and/or
    // 5 | 2 & 3 should be 5 | (2 & 3) = 5 | 2 = 7
    let result = 5 | 2 & 3
    return result
}
