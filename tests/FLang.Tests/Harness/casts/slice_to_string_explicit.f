//! TEST: slice_to_string_explicit
//! EXIT: 0
//! STDOUT: hello

import core.string
import core.io

pub fn main() i32 {
    let arr: [u8; 5] = [104, 101, 108, 108, 111]
    let bytes: u8[] = arr  // automatic cast
    let s: String = bytes as String
    println(s)
    return 0
}
