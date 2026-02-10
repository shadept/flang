//! TEST: string_builder_append_bool_string
//! EXIT: 0
//! STDOUT: true
//! STDOUT: false
//! STDOUT: hello world
//! STDOUT: abc123

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder_with_allocator(&alloc)

    // Bool true
    sb.append(true)
    println(sb.as_view())
    sb.clear()

    // Bool false
    sb.append(false)
    println(sb.as_view())
    sb.clear()

    // String append
    sb.append("hello ")
    sb.append("world")
    println(sb.as_view())
    sb.clear()

    // Mixed
    sb.append("abc")
    sb.append(123i32)
    println(sb.as_view())

    return 0
}
