//! TEST: directives_deprecated_enum
//! COMPILE-WARNING: W2001
//! EXIT: 0

#deprecated
enum OldColor {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let c: OldColor = OldColor.Red
    return 0
}
