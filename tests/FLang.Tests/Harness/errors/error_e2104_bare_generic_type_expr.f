//! TEST: error_e2020_bare_generic_type_expr
//! COMPILE-ERROR: E2104

// Bare generic type (without type args) in expression context should be an error.

type Box = struct(T) {
    value: T
}

pub fn main() i32 {
    const s = size_of(Box)
    return 0
}
