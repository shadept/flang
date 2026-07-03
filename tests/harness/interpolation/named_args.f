//! TEST: interp_named_args
//! EXIT: 0
//! STDOUT: k=9

import std.string_builder
import std.string
import std.allocator
import core.io

pub fn main() i32 {
    let buf = [0u8; 64]
    let fba = fixed_buffer_allocator(buf)
    let alloc = fba.allocator()

    let k = 9i32
    let msg = $(allocator=&alloc)"k={k}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
