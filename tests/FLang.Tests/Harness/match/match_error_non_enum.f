//! TEST: match_error_non_enum
//! COMPILE-ERROR: E2030

struct Point {
    x: i32
    y: i32
}

pub fn main() i32 {
    let p: Point = .{ x = 10, y = 20 }
    
    // Error: Cannot match on struct type
    return p match {
        Point => 0
    }
}

