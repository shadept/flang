//! TEST: error_e2019_struct_missing_fields
//! COMPILE-ERROR: E2015

// Note: Missing fields in struct construction reports E2015, not E2019.
// This is a discrepancy between documentation and implementation.
struct Point {
    x: i32
    y: i32
}

pub fn main() i32 {
    let p: Point = .{ x = 10 }  // ERROR: missing field `y`
    return p.x
}
