//! TEST: memcpy_basic
//! STDOUT: 456

// `copy_to` copies one buffer into another; it lowers to the byte copy `memcpy` used to spell.

import std.io.print

pub fn main() {
    let src: [i32; 3] = [123, 456, 789]
    let dst: [i32; 3]
    copy_to(src, dst)
    println(dst[1])
}
