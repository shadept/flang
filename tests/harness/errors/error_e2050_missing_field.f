//! TEST: error_e2050_missing_field
//! COMPILE-ERROR: E2050 struct literal missing field `y`

// Strict construction: a field left out would take whatever its slot's zero bytes mean.
type Point = struct {
    x: i32
    y: i32
}

pub fn main() i32 {
    let p = Point { x = 10i32 }
    return p.x
}
