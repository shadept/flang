//! TEST: struct_basic
//! EXIT: 42

struct Point {
    x: i32,
    y: i32
}

pub fn main() i32 {
    let p: Point = Point { x = 42, y = 10 }
    return p.x
}
