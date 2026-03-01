//! TEST: address_of_temporary
//! EXIT: 42

type Point = struct {
    x: i32
    y: i32
}

fn make_point(x: i32, y: i32) Point {
    return .{ x = x, y = y }
}

fn get_x(p: &Point) i32 {
    return p.x
}

pub fn main() i32 {
    return get_x(&make_point(42, 10))
}
