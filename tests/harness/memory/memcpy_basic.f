//! TEST: memcpy_basic
//! STDOUT: 456

// Test memcpy - copy data between two buffers

import std.mem

pub fn main() {
    // Source array
    let src: [i32; 3] = [123, 456, 789]

    // Destination array
    let dst: [i32; 3]

    memcpy(dst.ptr as &u8, src.ptr as &u8, 12)

    println(dst[1])
}
