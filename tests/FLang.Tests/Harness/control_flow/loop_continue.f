//! TEST: loop_continue
//! EXIT: 6

// Test loop with continue - sum only even iterations
pub fn main() i32 {
    let i: i32 = 0
    let sum: i32 = 0
    loop {
        i = i + 1
        if (i > 5) {
            break
        }
        if (i % 2 == 1) {
            continue
        }
        sum = sum + i
    }
    return sum  // 2 + 4 = 6
}
