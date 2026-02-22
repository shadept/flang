//! TEST: directives_deprecated_enum
//! COMPILE-WARNING: W2001
//! EXIT: 0

#deprecated
type OldColor = enum {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let _c: OldColor = OldColor.Red
    return 0
}
