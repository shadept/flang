//! TEST: string_builder_append_signed_hex_all
//! EXIT: 0
//! STDOUT: i8 -1: ff
//! STDOUT: i8 -128: 80
//! STDOUT: i16 -1: ffff
//! STDOUT: i16 -32768: 8000
//! STDOUT: i32 -1: ffffffff
//! STDOUT: i32 min: 80000000
//! STDOUT: i64 -1: ffffffffffffffff
//! STDOUT: i64 min: 8000000000000000
//! STDOUT: isize -1: ffffffffffffffff
//! STDOUT: isize min: 8000000000000000

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder(&alloc)

    // i8 negative as hex
    sb.append("i8 -1: ")
    sb.append(-1i8, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("i8 -128: ")
    sb.append(-128i8, "x")
    println(sb.as_view())
    sb.clear()

    // i16 negative as hex
    sb.append("i16 -1: ")
    sb.append(-1i16, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("i16 -32768: ")
    sb.append(-32768i16, "x")
    println(sb.as_view())
    sb.clear()

    // i32 negative as hex
    sb.append("i32 -1: ")
    sb.append(-1i32, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("i32 min: ")
    sb.append(-2147483648i32, "x")
    println(sb.as_view())
    sb.clear()

    // i64 negative as hex
    sb.append("i64 -1: ")
    sb.append(-1i64, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("i64 min: ")
    sb.append(-9223372036854775808i64, "x")
    println(sb.as_view())
    sb.clear()

    // isize negative as hex
    sb.append("isize -1: ")
    sb.append(-1isize, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("isize min: ")
    sb.append(-9223372036854775808isize, "x")
    println(sb.as_view())

    return 0
}
