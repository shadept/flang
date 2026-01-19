//! TEST: op_eq_basic
//! EXIT: 1

// Test op_eq for struct

struct Point {
    x: i32
}

pub fn op_eq(lhs: Point, rhs: Point) bool {
    return true
}

pub fn main() i32 {
    let a: Point = Point { x = 1 }
    let b: Point = Point { x = 2 }
    let result: bool = a == b
    let code: i32 = if (result) 1 else 0
    return code
}
