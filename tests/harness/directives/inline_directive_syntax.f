//! TEST: directives_inline_syntax
//! COMPILE-ERROR: E1001

// Old detached syntax for #foreign on type declarations should error
#foreign
pub type BadStruct = struct {
    x: i32,
}

pub fn main() i32 {
    return 0
}
