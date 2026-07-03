//! TEST: loop_basic
//! EXIT: 5

// Test basic loop with break
pub fn main() i32 {
    let count: i32 = 0
    loop {
        count = count + 1
        if (count == 5) {
            break
        }
    }
    return count
}
