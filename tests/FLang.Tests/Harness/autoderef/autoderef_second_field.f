//! TEST: autoderef_second_field
//! EXIT: 42

struct Point {
    x: i32,
    y: i32
}

pub fn getY(p: &Point) i32 {
    // Access second field - tests offset calculation with auto-deref
    return p.y
}

pub fn main() i32 {
    let p: Point = Point { x = 10, y = 42 }
    return getY(&p)
}
