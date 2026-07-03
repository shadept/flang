//! TEST: while_break
//! EXIT: 5

// Break inside a while exits the loop early, before the condition becomes false.
pub fn main() i32 {
    let n: i32 = 0
    while n < 1000 {
        n = n + 1
        if n == 5 {
            break
        }
    }
    return n
}
