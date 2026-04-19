//! TEST: interp_alloc_form
//! EXIT: 0
//! STDOUT: count=7

import std.string_builder
import std.string
import std.allocator
import core.io

pub fn main() i32 {
    let buf = [0u8; 64]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()

    let n = 7i32
    let msg = $(&alloc)"count={n}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
