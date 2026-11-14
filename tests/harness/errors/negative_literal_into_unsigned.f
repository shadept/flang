//! TEST: negative_literal_into_unsigned
//! COMPILE-ERROR: E2029

// E2029 covers a literal too small for its target as well as one too large: the
// negation is part of the value, and an unsigned type holds no negative one.

pub fn main() i32 {
    let b: u64 = -3
    return b as i32
}
