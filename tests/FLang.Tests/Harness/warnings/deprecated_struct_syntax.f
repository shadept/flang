//! TEST: deprecated_struct_syntax
//! COMPILE-WARNING: W1001
//! EXIT: 0

struct OldStyle {
    x: i32
}

pub fn main() i32 {
    let s: OldStyle = OldStyle { x = 1 }
    return 0
}
