//! TEST: op_sub_struct
//! EXIT: 8

// Test operator overloading with op_sub for a custom struct type

struct Vec2 {
    x: i32,
    y: i32
}

// Define op_sub for Vec2
pub fn op_sub(lhs: Vec2, rhs: Vec2) Vec2 {
    return Vec2 { x = lhs.x - rhs.x, y = lhs.y - rhs.y }
}

pub fn main() i32 {
    let a: Vec2 = Vec2 { x = 10, y = 7 }
    let b: Vec2 = Vec2 { x = 3, y = 2 }

    // This should use our op_sub function
    let c: Vec2 = a - b

    // c.x should be 7, c.y should be 5, total = 12 - but we return just sum = 12 % 256 = 12
    // Let's return c.x + c.y - 4 = 7 + 5 - 4 = 8
    return c.x + c.y - 4
}
