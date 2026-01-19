//! TEST: autoderef_assignment
//! EXIT: 100

struct Point {
    x: i32,
    y: i32
}

pub fn setX(p: &Point, value: i32) {
    // Auto-deref: p.x on &Point auto-dereferences for assignment
    p.x = value
}

pub fn main() i32 {
    let p: Point = Point { x = 15, y = 20 }
    setX(&p, 100)
    return p.x
}
