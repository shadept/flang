//! TEST: string_builder_append_unsigned_hex
//! EXIT: 0
//! STDOUT: u8: ff
//! STDOUT: u16: ffff
//! STDOUT: u32: ffffffff
//! STDOUT: u64: ffffffffffffffff
//! STDOUT: usize: ffffffffffffffff
//! STDOUT: u8 hex: 80
//! STDOUT: u16 hex: 8000
//! STDOUT: u32 hex: 80000000
//! STDOUT: u64 hex: 8000000000000000
//! STDOUT: usize hex: 8000000000000000

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder(&alloc)

    // Max values in hex
    sb.append("u8: ")
    sb.append(255u8, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("u16: ")
    sb.append(65535u16, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("u32: ")
    sb.append(4294967295u32, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("u64: ")
    sb.append(18446744073709551615u64, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("usize: ")
    sb.append(18446744073709551615usize, "x")
    println(sb.as_view())
    sb.clear()

    // High bit set (tests sign extension issues)
    sb.append("u8 hex: ")
    sb.append(128u8, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("u16 hex: ")
    sb.append(32768u16, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("u32 hex: ")
    sb.append(2147483648u32, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("u64 hex: ")
    sb.append(9223372036854775808u64, "x")
    println(sb.as_view())
    sb.clear()

    sb.append("usize hex: ")
    sb.append(9223372036854775808usize, "x")
    println(sb.as_view())

    return 0
}
