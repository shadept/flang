//! TEST: while_parens
//! EXIT: 3

// Parenthesized condition is accepted, mirroring `if (x)`. (`for` no longer accepts header parens — they were dropped per RFC-006.)
pub fn main() i32 {
    let n: i32 = 0
    while (n < 3) {
        n = n + 1
    }
    return n
}
