//! TEST: while_basic
//! EXIT: 10

// Basic while loop — exits when condition becomes false.
pub fn main() i32 {
    let n: i32 = 0
    while n < 10 {
        n = n + 1
    }
    return n
}
