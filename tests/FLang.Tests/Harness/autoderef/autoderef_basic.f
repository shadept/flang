//! TEST: autoderef_basic
//! EXIT: 35

struct Point {
    x: i32,
    y: i32
}

pub fn sum(p: &Point) i32 {
    // Auto-deref: p.x on &Point accesses field directly through pointer
    return p.x + p.y
}

pub fn main() i32 {
    let p: Point = Point { x = 15, y = 20 }
    return sum(&p)
}
