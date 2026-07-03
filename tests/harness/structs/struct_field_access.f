//! TEST: struct_field_access
//! EXIT: 52

type Point = struct {
    x: i32,
    y: i32
}

pub fn main() i32 {
    let p: Point = Point { x = 42, y = 10 }
    return p.x + p.y
}
