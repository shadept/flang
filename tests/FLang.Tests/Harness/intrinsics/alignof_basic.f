//! TEST: alignof_basic
//! EXIT: 4

// Test align_of intrinsic with basic integer type
// Expected: alignof(i32) = 4 bytes

import core.rtti

pub fn main() i32 {
    return align_of(i32) as i32
}
