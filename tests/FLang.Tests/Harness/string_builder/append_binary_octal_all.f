//! TEST: string_builder_append_binary_octal_all
//! EXIT: 0
//! STDOUT: u8 bin: 11111111
//! STDOUT: u8 oct: 377
//! STDOUT: u16 bin: 1111111111111111
//! STDOUT: u16 oct: 177777
//! STDOUT: i8 -1 bin: 11111111
//! STDOUT: i8 -1 oct: 377
//! STDOUT: i16 -1 bin: 1111111111111111
//! STDOUT: i16 -1 oct: 177777

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 512]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder_with_allocator(&alloc)

    // Unsigned binary/octal
    sb.append("u8 bin: ")
    sb.append(255u8, "b")
    println(sb.as_view())
    sb.clear()

    sb.append("u8 oct: ")
    sb.append(255u8, "o")
    println(sb.as_view())
    sb.clear()

    sb.append("u16 bin: ")
    sb.append(65535u16, "b")
    println(sb.as_view())
    sb.clear()

    sb.append("u16 oct: ")
    sb.append(65535u16, "o")
    println(sb.as_view())
    sb.clear()

    // Signed negative in binary/octal (two's complement)
    sb.append("i8 -1 bin: ")
    sb.append(-1i8, "b")
    println(sb.as_view())
    sb.clear()

    sb.append("i8 -1 oct: ")
    sb.append(-1i8, "o")
    println(sb.as_view())
    sb.clear()

    sb.append("i16 -1 bin: ")
    sb.append(-1i16, "b")
    println(sb.as_view())
    sb.clear()

    sb.append("i16 -1 oct: ")
    sb.append(-1i16, "o")
    println(sb.as_view())

    return 0
}
