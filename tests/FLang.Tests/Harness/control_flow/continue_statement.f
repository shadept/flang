//! TEST: continue_statement_test
//! EXIT: 4
pub fn main() i32 {
    let count: i32 = 0
    for (i in 0..5 as i32) {
        if (i == 2) {
            continue
        }
        count = count + 1
    }
    return count
}
