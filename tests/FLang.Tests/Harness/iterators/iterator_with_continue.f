//! TEST: iterator_with_continue
//! EXIT: 9

pub fn main() i32 {
    let sum: i32 = 0
    for (i in 0..6) {
        if (i == 2) {
            continue  // Skip 2
        }
        if (i == 4) {
            continue  // Skip 4
        }
        sum = sum + i as i32
    }
    return sum  // 0 + 1 + 3 + 5 = 9
}
