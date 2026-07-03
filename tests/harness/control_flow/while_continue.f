//! TEST: while_continue
//! EXIT: 9

// Continue re-evaluates the condition. Counts iterations 1..=10, skipping 5.
pub fn main() i32 {
    let i: i32 = 0
    let count: i32 = 0
    while i < 10 {
        i = i + 1
        if i == 5 {
            continue
        }
        count = count + 1
    }
    return count
}
