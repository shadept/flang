//! TEST: iterator_range_empty
//! EXIT: 0

pub fn main() i32 {
    let sum: i32 = 0
    for (i in 5..5) {  // Empty range (start == end)
        sum = sum + i as i32
    }
    return sum  // Should be 0 (no iterations)
}
