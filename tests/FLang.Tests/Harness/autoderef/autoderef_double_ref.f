//! TEST: autoderef_double_ref
//! EXIT: 99

struct Point {
    x: i32,
    y: i32
}

pub fn getValue(pp: &&Point) i32 {
    // Auto-deref should work recursively: pp is &&Point
    // pp.x should auto-deref twice to access field
    return pp.x
}

pub fn main() i32 {
    let p: Point = Point { x = 99, y = 20 }
    let ptr: &Point = &p
    return getValue(&ptr)
}
