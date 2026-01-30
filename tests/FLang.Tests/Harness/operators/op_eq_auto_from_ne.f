//! TEST: op_eq_auto_from_ne
//! EXIT: 1

// Test auto-deriving op_eq from op_ne (should emit not op_ne)

struct Point {
    x: i32,
    y: i32
}

pub fn op_ne(lhs: Point, rhs: Point) bool {
    return lhs.x != rhs.x
}

pub fn main() i32 {
    let a: Point = Point { x = 10, y = 20 }
    let b: Point = Point { x = 10, y = 99 }

    // op_eq is not defined, so compiler should auto-derive it as !op_ne
    return if (a == b) 1 else 0
}
