//! TEST: move_copyable_struct
//! COMPILE-WARNING: W2005
//! EXIT: 4

type Point = struct {
    x: i32
    y: i32
}

// `Point` has no `owned` field, so nothing is transferred and `p` stays usable.
pub fn main() i32 {
    let p = Point { x = 1, y = 2 }
    let q = move p                 // warning W2005
    return p.x + q.x + q.y
}
