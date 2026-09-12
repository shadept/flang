//! TEST: directives_unknown_directive_decl
//! COMPILE-ERROR: E2130 unknown directive `#noexist`

#noexist
fn foo() i32 {
    return 42
}

pub fn main() i32 {
    return foo() - 42
}
