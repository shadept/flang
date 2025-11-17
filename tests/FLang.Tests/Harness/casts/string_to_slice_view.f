//! TEST: string_to_slice_view
//! EXIT: 1

import core.string

pub fn main() i32 {
    let s: String = "hi"
    let bytes: u8[] = s as u8[]
    return s.len == bytes.len
}
