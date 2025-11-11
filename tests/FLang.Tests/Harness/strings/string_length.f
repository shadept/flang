//! TEST: string_length
//! EXIT: 13
import core.string

pub fn main() i32 {
    let s1: String = "hello"
    let s2: String = "world!!!"
    return s1.len + s2.len
}
