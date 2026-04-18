//! TEST: while_parens
//! EXIT: 3

// Parenthesized condition is accepted, mirroring `if (x)` and `for (i in r)`.
pub fn main() i32 {
    let n: i32 = 0
    while (n < 3) {
        n = n + 1
    }
    return n
}
