//! TEST: string_builder_append_signed_hex
//! EXIT: 0
//! STDOUT: ffffffff
//! STDOUT: ffffffffffffff85
//! STDOUT: 2a

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder_with_allocator(&alloc)

    // Negative i32 as hex (32-bit width preserved)
    sb.append(-1i32, "x")
    println(sb.as_view())
    sb.clear()

    // Negative i64 as hex
    sb.append(-123i64, "x")
    println(sb.as_view())
    sb.clear()

    // Positive signed as hex
    sb.append(42i32, "x")
    println(sb.as_view())

    return 0
}
