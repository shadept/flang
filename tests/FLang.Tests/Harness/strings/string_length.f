//! TEST: string_length
//! EXIT: 13
//! STDOUT: hello
//! STDOUT: world!!!
import core.string
import core.io

pub fn main() i32 {
    let s1: String = "hello"
    let s2: String = "world!!!"
    println(s1)
    println(s2)
    return s1.len + s2.len
}

