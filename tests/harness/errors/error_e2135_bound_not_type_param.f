//! TEST: error_e2135_bound_not_type_param
//! COMPILE-ERROR: E2135 `U`
//! EXIT: 1

fn pick(x: $T) T where U: copyable {
    return x
}

pub fn main() i32 {
    return pick(1i32)
}
