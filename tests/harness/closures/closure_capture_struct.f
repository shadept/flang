//! TEST: closure_capture_struct
//! EXIT: 30

// Struct captured by reference: the closure reads the fields of the outer `p`.

type Point = struct { x: i32, y: i32 }

pub fn main() i32 {
    let p = Point { x = 10, y = 20 }
    let f = { => p.x + p.y }
    return f()
}
