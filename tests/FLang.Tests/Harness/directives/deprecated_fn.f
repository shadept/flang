//! TEST: directives_deprecated_fn
//! COMPILE-WARNING: W2002
//! EXIT: 0

#deprecated("use bar() instead")
fn foo() i32 {
    return 42
}

fn bar() i32 {
    return 42
}

pub fn main() i32 {
    let x: i32 = foo()
    return 0
}
