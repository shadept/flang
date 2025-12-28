//! TEST: string_escape
//! EXIT: 11
//! STDOUT: hello
//! STDOUT: world
import core.string
import core.io

pub fn main() i32 {
    let s: String = "hello\nworld"
    println(s)
    return s.len as i32
}

