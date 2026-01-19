//! TEST: autoderef_assign_second
//! EXIT: 88

struct Point {
    x: i32,
    y: i32
}

pub fn setY(p: &Point, value: i32) {
    // Assign to second field through auto-deref
    p.y = value
}

pub fn main() i32 {
    let p: Point = Point { x = 10, y = 20 }
    setY(&p, 88)
    return p.y
}
