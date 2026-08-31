//! TEST: error_e2035_mutual_recursive
//! COMPILE-ERROR: E2035

// Two structs that contain each other by value have no finite size either. The cycle is cut at
// detection, so the walk that finds it terminates on both.
type A = struct {
    b: B
    tag: i32
}

type B = struct {
    a: A
    tag: i32
}

pub fn main() i32 {
    return 0
}
