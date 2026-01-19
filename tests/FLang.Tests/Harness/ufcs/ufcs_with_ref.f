//! TEST: ufcs_with_ref
//! EXIT: 100

struct Point {
    x: i32
    y: i32
}

// Takes reference to Point
fn sum(p: &Point) i32 {
    return p.*.x + p.*.y
}

pub fn main() i32 {
    let p = Point { x = 40, y = 60 }
    // UFCS: p.sum() -> sum(&p)
    return p.sum()
}
