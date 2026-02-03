//! TEST: string_builder_append_floats
//! SKIP: float formatting needs work
//! EXIT: 0
//! STDOUT: 3.141592
//! STDOUT: -2.718281
//! STDOUT: 0.000000
//! STDOUT: 123.456001
//! STDOUT: 1000000.000000

import std.string_builder
import std.allocator

pub fn main() i32 {
    let buf = [0u8; 256]
    let fba = fixed_buffer_allocator(buf as u8[])
    let alloc = fba.allocator()
    let sb = string_builder(&alloc)

    // Pi
    sb.append(3.141592f64)
    println(sb.as_view())
    sb.clear()

    // Negative float
    sb.append(-2.718281f64)
    println(sb.as_view())
    sb.clear()

    // Zero
    sb.append(0.0f64)
    println(sb.as_view())
    sb.clear()

    // f32
    sb.append(123.456f32)
    println(sb.as_view())
    sb.clear()

    // Large number
    sb.append(1000000.0f64)
    println(sb.as_view())

    return 0
}
