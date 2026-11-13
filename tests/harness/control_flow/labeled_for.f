//! TEST: labeled_for
//! STDOUT: 0 0
//! STDOUT: 1 0
//! STDOUT: 2 0
//! STDOUT: 2 1
//! EXIT: 0

// `continue outer` starts the outer loop's next iteration; `break outer` leaves both loops.
import std.io.print
import std.string_builder

pub fn main() i32 {
    outer: for i in 0..5 as i32 {
        for j in 0..3 as i32 {
            if i < 2 and j == 1 {
                continue outer
            }
            if i == 2 and j == 2 {
                break outer
            }
            println($"{i} {j}")
        }
    }
    return 0
}
