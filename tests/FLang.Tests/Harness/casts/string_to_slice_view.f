//! TEST: string_to_slice_view
//! EXIT: 2

import core.string

pub fn main() i32 {
    let s: String = "hi"
    // View cast String -> u8[]; no further use, just smoke the cast
    let _bytes: u8[] = s as u8[]
    return s.len
}
