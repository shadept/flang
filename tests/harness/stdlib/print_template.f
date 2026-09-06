//! TEST: print_template
//! EXIT: 0
//! STDOUT: this and that
//! STDOUT: b a a
//! STDOUT: ff 0007
//! STDOUT: {1} {}
//! STDOUT: 1 2 3
//! STDOUT: x=3.5 ok=true

import std.io.print

pub fn main() i32 {
    println("{} and {}", "this", "that")
    println("{1} {} {0}", "a", "b")
    println("{:x} {1:04}", 255i32, 7i32)
    println("{{{}}} {{}}", 1i32, 2i32)
    println("{} {} {}", 1i32, 2i32, 3i32)
    println("x={} ok={}", 3.5f64, true)
    return 0
}
