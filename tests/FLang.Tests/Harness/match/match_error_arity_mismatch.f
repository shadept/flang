//! TEST: match_error_arity_mismatch
//! COMPILE-ERROR: E2032

enum Point {
    Origin
    Coordinate(i32, i32)
}

pub fn main() i32 {
    let p: Point = Point.Coordinate(10, 20)
    
    // Error: Coordinate has 2 fields, pattern has 1
    return p match {
        Origin => 0,
        Coordinate(x) => x
    }
}

