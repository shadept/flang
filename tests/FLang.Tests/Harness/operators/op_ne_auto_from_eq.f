//! TEST: op_ne_auto_from_eq
//! EXIT: 1

// Test auto-deriving op_ne from op_eq (should emit not op_eq)

struct Point {
    x: i32,
    y: i32
}

pub fn op_eq(lhs: Point, rhs: Point) bool {
    return lhs.x == rhs.x
}

pub fn main() i32 {
    let a: Point = Point { x = 10, y = 20 }
    let b: Point = Point { x = 99, y = 20 }

    // op_ne is not defined, so compiler should auto-derive it as !op_eq
    return if (a != b) 1 else 0
}
