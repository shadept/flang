//! TEST: string_builder_append_format_hex
//! EXIT: 0
//! STDOUT: ff
//! STDOUT: FF
//! STDOUT: deadbeef
//! STDOUT: DEADBEEF
//! STDOUT: 0
//! STDOUT: 7fffffffffffffff

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder(&alloc)

    // Lowercase hex
    sb.append(255u8, "x")
    println(sb.as_view())
    sb.clear()

    // Uppercase hex
    sb.append(255u8, "X")
    println(sb.as_view())
    sb.clear()

    // Larger hex lowercase
    sb.append(3735928559u32, "x")
    println(sb.as_view())
    sb.clear()

    // Larger hex uppercase
    sb.append(3735928559u32, "X")
    println(sb.as_view())
    sb.clear()

    // Zero in hex
    sb.append(0u32, "x")
    println(sb.as_view())
    sb.clear()

    // i64 max in hex
    sb.append(9223372036854775807i64, "x")
    println(sb.as_view())

    return 0
}
