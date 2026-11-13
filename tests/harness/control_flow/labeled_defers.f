//! TEST: labeled_defers
//! STDOUT: inner 0
//! STDOUT: outer 0
//! STDOUT: inner 1
//! STDOUT: outer 1
//! STDOUT: end
//! EXIT: 0

// A labeled jump fires the defers of every scope it leaves, innermost first.
import std.io.print
import std.string_builder

pub fn main() i32 {
    outer: for i in 0..2 as i32 {
        defer println($"outer {i}")
        for _j in 0..2 as i32 {
            defer println($"inner {i}")
            if i == 0 {
                continue outer
            }
            break outer
        }
    }
    println("end")
    return 0
}
