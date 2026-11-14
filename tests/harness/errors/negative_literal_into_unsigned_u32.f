//! TEST: negative_literal_into_unsigned_u32
//! COMPILE-ERROR: E2029

pub fn main() i32 {
    let c: u32 = -1
    return c as i32
}
