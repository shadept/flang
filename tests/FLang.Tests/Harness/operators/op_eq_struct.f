//! TEST: op_eq_struct
//! EXIT: 1

// Test operator overloading with op_eq for a custom struct type

struct Point {
    x: i32,
    y: i32
}

// Define op_eq for Point
pub fn op_eq(lhs: Point, rhs: Point) bool {
    return lhs.x == rhs.x
}

pub fn main() i32 {
    let a: Point = Point { x = 10, y = 20 }
    let b: Point = Point { x = 10, y = 99 }  // Same x, different y

    // This should use our op_eq function (only compares x)
    return if (a == b) 1 else 0
}
