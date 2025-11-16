//! TEST: string_to_slice_implicit
//! EXIT: 2

import core.string

fn takes_bytes(b: u8[]) i32 {
    return b.len
}

pub fn main() i32 {
    let s: String = "hi"
    return takes_bytes(s)  // implicit reinterpretation
}
