//! TEST: error_e2020_invalid_cast
//! COMPILE-ERROR: E2020

struct Foo { x: i32 }

pub fn main() i32 {
    let f: Foo = .{ x = 42 }
    let x: i32 = f as i32  // ERROR: invalid cast `Foo` to `i32`
    return x
}
