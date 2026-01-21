//! TEST: error_e2011_ufcs_receiver_mismatch
//! COMPILE-ERROR: E2011

struct Fba {
    data: i32
}

fn allocator(x: &i32) i32 {
    return x.*
}

pub fn main() i32 {
    const fba: Fba = .{ data = 42 }
    const result = fba.allocator()  // ERROR: no function `allocator` found for receiver type `Fba`
    return result
}
