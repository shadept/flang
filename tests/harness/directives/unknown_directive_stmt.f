//! TEST: directives_unknown_directive_stmt
//! COMPILE-ERROR: E2130 unknown directive `#bogus`

pub fn main() i32 {
    #bogus(1, 2)
    return 0
}
