//! TEST: interp_both_args
//! EXIT: 0
//! STDOUT: x=42

import std.string_builder
import std.string
import std.allocator
import core.io

pub fn main() i32 {
    let buf = [0u8; 64]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()

    let x = 42i32
    let msg = $(32, &alloc)"x={x}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
