//! TEST: negative_suffixed_literal_into_unsigned
//! COMPILE-ERROR: E2029

pub fn main() i32 {
    let d = -3u16
    return d as i32
}
