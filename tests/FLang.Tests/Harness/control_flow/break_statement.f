//! TEST: break_statement_test
//! EXIT: 3
pub fn main() i32 {
    let count: i32 = 0
    for (i in 0..10) {
        if (i == 3) {
            break
        }
        count = count + 1
    }
    return count
}
