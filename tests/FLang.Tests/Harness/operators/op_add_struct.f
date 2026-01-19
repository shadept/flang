//! TEST: op_add_struct
//! EXIT: 15

// Test operator overloading with op_add for a custom struct type

struct Vec2 {
    x: i32,
    y: i32
}

// Define op_add for Vec2
pub fn op_add(lhs: Vec2, rhs: Vec2) Vec2 {
    return Vec2 { x = lhs.x + rhs.x, y = lhs.y + rhs.y }
}

pub fn main() i32 {
    let a: Vec2 = Vec2 { x = 5, y = 3 }
    let b: Vec2 = Vec2 { x = 2, y = 5 }

    // This should use our op_add function
    let c: Vec2 = a + b

    // c.x should be 7, c.y should be 8, total = 15
    return c.x + c.y
}
