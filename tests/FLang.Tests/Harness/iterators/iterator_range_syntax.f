//! TEST: iterator_range_syntax
//! EXIT: 10

pub fn main() i32 {
    let sum: i32 = 0
    for (i in 0..5 as i32) {
        sum = sum + i
    }
    return sum  // 0 + 1 + 2 + 3 + 4 = 10
}
