//! TEST: sizeof_struct
//! EXIT: 12

// Test size_of with struct type
// struct Point { x: i32, y: i32, z: i32 } = 4 + 4 + 4 = 12 bytes

import core.rtti

struct Point {
    x: i32,
    y: i32,
    z: i32
}

pub fn main() i32 {
    return size_of(Point) as i32
}
