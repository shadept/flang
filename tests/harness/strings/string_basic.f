//! TEST: string_basic
//! EXIT: 5
//! STDOUT: hello
import core.string

import std.io.print

pub fn main() i32 {
    let s: String = "hello"
    println(s)
    return s.len as i32
}
