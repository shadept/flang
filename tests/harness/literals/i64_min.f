//! TEST: i64_min_literal
//! EXIT: 0
pub fn main() i32 {
    // i64 min is -9223372036854775808
    // We express it as negation of a literal that would overflow if parsed as i64
    let min: i64 = -9223372036854775808i64
    return 0
}
