//! TEST: memset_basic
//! EXIT: 42

// Test memset - fill memory with a byte value

import core.mem

pub fn main() i32 {
    // Array of bytes
    let arr: [u8; 5] = [0, 0, 0, 0, 0]

    // Fill array with value 42
    memset(&arr[0], 42, 5)

    return arr[0] as i32
}
