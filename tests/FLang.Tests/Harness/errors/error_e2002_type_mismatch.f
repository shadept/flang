//! TEST: error_e2002_type_mismatch
//! COMPILE-ERROR: E2002

struct Foo { x: i32 }

pub fn returns_foo() Foo {
    return .{ x = 42 }
}

pub fn main() i32 {
    let x: i32 = returns_foo()  // ERROR: expected `i32`, found `Foo`
    return x
}
