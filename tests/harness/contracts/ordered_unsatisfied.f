//! TEST: ordered_unsatisfied
//! COMPILE-ERROR: E2134
//! EXIT: 1

// `max` orders its arguments; a type with no `op_cmp` is refused at the call.
type Point = struct {
    x: i32
}

pub fn main() i32 {
    const p = max(Point { x = 1 }, Point { x = 2 }) // error E2134
    return p.x
}
