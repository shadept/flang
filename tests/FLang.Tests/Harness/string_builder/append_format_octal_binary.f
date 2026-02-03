//! TEST: string_builder_append_format_octal_binary
//! EXIT: 0
//! STDOUT: 377
//! STDOUT: 11111111
//! STDOUT: 52
//! STDOUT: 101010
//! STDOUT: 0
//! STDOUT: 0

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder(&alloc)

    // Octal 255
    sb.append(255u8, "o")
    println(sb.as_view())
    sb.clear()

    // Binary 255
    sb.append(255u8, "b")
    println(sb.as_view())
    sb.clear()

    // Octal 42
    sb.append(42u8, "o")
    println(sb.as_view())
    sb.clear()

    // Binary 42
    sb.append(42u8, "b")
    println(sb.as_view())
    sb.clear()

    // Zero octal
    sb.append(0u8, "o")
    println(sb.as_view())
    sb.clear()

    // Zero binary
    sb.append(0u8, "b")
    println(sb.as_view())

    return 0
}
