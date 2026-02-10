//! TEST: string_builder_append_integers
//! EXIT: 0
//! STDOUT: 0
//! STDOUT: 42
//! STDOUT: -123
//! STDOUT: 255
//! STDOUT: 65535
//! STDOUT: 4294967295
//! STDOUT: 9223372036854775807
//! STDOUT: -9223372036854775807

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder_with_allocator(&alloc)

    // Zero
    sb.append(0i32)
    println(sb.as_view())
    sb.clear()

    // Positive i32
    sb.append(42i32)
    println(sb.as_view())
    sb.clear()

    // Negative i32
    sb.append(-123i32)
    println(sb.as_view())
    sb.clear()

    // u8 max
    sb.append(255u8)
    println(sb.as_view())
    sb.clear()

    // u16 max
    sb.append(65535u16)
    println(sb.as_view())
    sb.clear()

    // u32 max
    sb.append(4294967295u32)
    println(sb.as_view())
    sb.clear()

    // i64 max (parser can't handle u64 max)
    sb.append(9223372036854775807i64)
    println(sb.as_view())
    sb.clear()

    // Large negative i64
    sb.append(-9223372036854775807i64)
    println(sb.as_view())

    return 0
}
