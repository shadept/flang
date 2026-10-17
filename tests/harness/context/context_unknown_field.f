//! TEST: context_unknown_field
//! COMPILE-ERROR: E2150
//! EXIT: 1

context depth: u32 = 0

pub fn main() i32 {
    context(dpeth = 1u32) { // error E2150
        return 0
    }
    return 1
}
