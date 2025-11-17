//! TEST: memcpy_basic
//! EXIT: 123

// Test memcpy - copy data between two buffers

import core.mem

pub fn main() i32 {
    // Source array
    let src: [i32; 3] = [123, 456, 789]

    // Destination array
    let dst: [i32; 3]

    // Copy first element (4 bytes)
    memcpy(dst, src, 4)

    return dst[0]
}
