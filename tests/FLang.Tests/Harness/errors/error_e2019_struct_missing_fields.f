//! TEST: struct_partial_init
//! EXIT: 10

// Partial struct initialization: unspecified fields default to zero.
type Point = struct {
    x: i32
    y: i32
}

pub fn main() i32 {
    let p: Point = .{ x = 10 }  // y defaults to 0
    return p.x + p.y
}
