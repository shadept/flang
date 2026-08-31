//! TEST: error_e2050_missing_field_anon
//! COMPILE-ERROR: E2050 struct literal missing field `y`

// The anonymous form is checked once the context binds it to a declared type; without this the
// rule has a hole the `.{ ... }` spelling drives straight through.
type Point = struct {
    x: i32
    y: i32
}

pub fn main() i32 {
    let p: Point = .{ x = 10i32 }
    return p.x
}
