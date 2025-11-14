//! TEST: string_to_slice_implicit
//! EXIT: 0

import core.string

fn takes_bytes(b: u8[]) i32 {
    return 0
}

pub fn main() i32 {
    let s: String = "hi"
    let _ = takes_bytes(s)  // implicit reinterpretation
    return 0
}
