//! TEST: string_builder_append_all_int_sizes
//! EXIT: 0
//! STDOUT: u8: 0 127 255
//! STDOUT: u16: 0 32767 65535
//! STDOUT: u32: 0 2147483647 4294967295
//! STDOUT: u64: 0 9223372036854775807 18446744073709551615
//! STDOUT: usize: 0 9223372036854775807 18446744073709551615
//! STDOUT: i8: 0 127 -128
//! STDOUT: i16: 0 32767 -32768
//! STDOUT: i32: 0 2147483647 -2147483648
//! STDOUT: i64: 0 9223372036854775807 -9223372036854775808
//! STDOUT: isize: 0 9223372036854775807 -9223372036854775808

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder_with_allocator(&alloc)

    // Test all unsigned types: zero, half-max, max
    sb.append("u8: ")
    sb.append(0u8)
    sb.append(" ")
    sb.append(127u8)
    sb.append(" ")
    sb.append(255u8)
    println(sb.as_view())
    sb.clear()

    sb.append("u16: ")
    sb.append(0u16)
    sb.append(" ")
    sb.append(32767u16)
    sb.append(" ")
    sb.append(65535u16)
    println(sb.as_view())
    sb.clear()

    sb.append("u32: ")
    sb.append(0u32)
    sb.append(" ")
    sb.append(2147483647u32)
    sb.append(" ")
    sb.append(4294967295u32)
    println(sb.as_view())
    sb.clear()

    sb.append("u64: ")
    sb.append(0u64)
    sb.append(" ")
    sb.append(9223372036854775807u64)
    sb.append(" ")
    sb.append(18446744073709551615u64)
    println(sb.as_view())
    sb.clear()

    sb.append("usize: ")
    sb.append(0usize)
    sb.append(" ")
    sb.append(9223372036854775807usize)
    sb.append(" ")
    sb.append(18446744073709551615usize)
    println(sb.as_view())
    sb.clear()

    // Test all signed types: zero, max, min
    sb.append("i8: ")
    sb.append(0i8)
    sb.append(" ")
    sb.append(127i8)
    sb.append(" ")
    sb.append(-128i8)
    println(sb.as_view())
    sb.clear()

    sb.append("i16: ")
    sb.append(0i16)
    sb.append(" ")
    sb.append(32767i16)
    sb.append(" ")
    sb.append(-32768i16)
    println(sb.as_view())
    sb.clear()

    sb.append("i32: ")
    sb.append(0i32)
    sb.append(" ")
    sb.append(2147483647i32)
    sb.append(" ")
    sb.append(-2147483648i32)
    println(sb.as_view())
    sb.clear()

    sb.append("i64: ")
    sb.append(0i64)
    sb.append(" ")
    sb.append(9223372036854775807i64)
    sb.append(" ")
    sb.append(-9223372036854775808i64)
    println(sb.as_view())
    sb.clear()

    sb.append("isize: ")
    sb.append(0isize)
    sb.append(" ")
    sb.append(9223372036854775807isize)
    sb.append(" ")
    sb.append(-9223372036854775808isize)
    println(sb.as_view())

    return 0
}
