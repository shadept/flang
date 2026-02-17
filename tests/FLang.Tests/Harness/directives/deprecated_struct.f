//! TEST: directives_deprecated_struct
//! COMPILE-WARNING: W2001
//! EXIT: 0

#deprecated("use NewFoo instead")
type OldFoo = struct {
    x: i32
}

type NewFoo = struct {
    x: i32
}

pub fn main() i32 {
    let f: OldFoo = OldFoo { x = 42 }
    return 0
}
