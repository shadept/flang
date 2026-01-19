//! TEST: error_e2014_field_not_found
//! COMPILE-ERROR: E2014

struct Point {
    x: i32
    y: i32
}

pub fn main() i32 {
    let p: Point = .{ x = 10, y = 20 }
    return p.z  // ERROR: no field `z` on type `Point`
}
