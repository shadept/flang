//! TEST: error_e2004_ufcs_function_not_found
//! COMPILE-ERROR: E2004

type Fba = struct {
    data: i32
}

pub fn main() i32 {
    const fba: Fba = .{ data = 42 }
    const result = fba.nonexistent()  // ERROR: function `nonexistent` does not exist
    return result
}
