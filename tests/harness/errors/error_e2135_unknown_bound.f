//! TEST: error_e2135_unknown_bound
//! COMPILE-ERROR: E2135 sortable
//! EXIT: 1

fn pick(x: $T) T where T: sortable {
    return x
}

pub fn main() i32 {
    return pick(1i32)
}
