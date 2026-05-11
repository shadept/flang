//! TEST: from_c_string_strlen
//! EXIT: 5
//! STDOUT: hello
import core.string
import core.io

pub fn main() i32 {
    let lit: String = "hello"
    let s = from_c_string(lit.ptr)
    println(s)
    return s.len as i32
}
