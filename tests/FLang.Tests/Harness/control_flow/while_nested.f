//! TEST: while_nested
//! EXIT: 6

// Nested while loops. Inner break only exits the inner loop.
pub fn main() i32 {
    let total: i32 = 0
    let i: i32 = 0
    while i < 3 {
        let j: i32 = 0
        while j < 10 {
            if j == 2 {
                break
            }
            j = j + 1
            total = total + 1
        }
        i = i + 1
    }
    return total
}
