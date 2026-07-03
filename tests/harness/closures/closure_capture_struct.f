//! TEST: closure_capture_struct
//! EXIT: 30

// Struct captured by value. Mutating the original after the lambda literal is
// built must not affect the closure's snapshot.

type Point = struct { x: i32, y: i32 }

pub fn main() i32 {
    let p = Point { x = 10, y = 20 }
    let f = fn() i32 { p.x + p.y }
    return f()
}
