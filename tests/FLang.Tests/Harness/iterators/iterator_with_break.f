//! TEST: iterator_with_break
//! EXIT: 3

pub fn main() i32 {
    let sum: i32 = 0
    for (i in 0..10) {
        if (i >= 3) {
            break
        }
        sum = sum + i as i32
    }
    return sum  // 0 + 1 + 2 = 3
}
