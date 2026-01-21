//! TEST: error_e2011_ufcs_field_not_callable
//! COMPILE-ERROR: E2011

struct Fba {
    allocator: i32
}

pub fn main() i32 {
    const fba: Fba = .{ allocator = 42 }
    const result = fba.allocator()  // ERROR: `allocator` is a field of `Fba`, not a method
    return result
}
