//! TEST: struct_parameter
//! EXIT: 15

struct Point {
    x: i32,
    y: i32
}

pub fn getX(p: Point) i32 {
    return p.x
}

pub fn main() i32 {
    let p: Point = Point { x: 15, y: 20 }
    return getX(p)
}
