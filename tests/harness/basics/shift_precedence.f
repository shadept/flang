//! TEST: shift_precedence
//! EXIT: 0
// Shifts have lower precedence than + - but higher than & | ^
pub fn main() i32 {
    // 1 + 2 << 3 should be (1 + 2) << 3 = 3 << 3 = 24
    let a: i32 = 1 + 2 << 3
    if (a != 24) { return 1 }

    // 16 >> 2 & 3 should be (16 >> 2) & 3 = 4 & 3 = 0
    let b: i32 = 16 >> 2 & 3
    if (b != 0) { return 2 }

    return 0
}
