//! TEST: iterator_range_basic
//! EXIT: 6

import core.range

pub fn main() i32 {
    let sum: i32 = 0
    let r: Range = .{ start = 0, end = 4 }
    for (i in r) {
        sum = sum + i as i32
    }
    return sum  // 0 + 1 + 2 + 3 = 6
}
