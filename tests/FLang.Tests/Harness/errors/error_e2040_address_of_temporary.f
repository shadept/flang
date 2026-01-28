//! TEST: error_e2040_address_of_temporary
//! COMPILE-ERROR: E2040

struct Point {
    x: i32
    y: i32
}

pub fn main() {
    let p: &Point = &.{ x = 1, y = 2 }
}
