//! TEST: iterator_range_basic
//! EXIT: 6

import core.range

pub fn main() i32 {
    let sum: i32 = 0
    let r = 0..4 as i32
    for (i in r) {
        sum = sum + i
    }
    return sum  // 0 + 1 + 2 + 3 = 6
}
