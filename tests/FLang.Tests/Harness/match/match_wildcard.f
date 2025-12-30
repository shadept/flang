//! TEST: match_wildcard
//! EXIT: 10

enum Point {
    Origin
    OnXAxis(i32)
    OnYAxis(i32)
    Coordinate(i32, i32)
}

pub fn main() i32 {
    let p1: Point = Point.Coordinate(10, 20)
    let p2: Point = Point.OnXAxis(5)
    
    // Use wildcard to ignore values we don't care about
    let r1 = p1 match {
        Origin => 0,
        OnXAxis(_) => 1,
        OnYAxis(_) => 2,
        Coordinate(x, _) => x
    }
    
    let r2: i32 = p2 match {
        OnXAxis(_) => 0,
        else => 100
    }
    
    return r1 + r2
}

