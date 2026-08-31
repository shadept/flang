//! TEST: negative_literal_into_unsigned
//! SKIP: E2029 does not see the negation; see known-issues
//! COMPILE-ERROR: E2029

// E2029 catches a literal too large for its target (`let b: u8 = 300`) but not
// one too small. The value stored is the two's-complement bit pattern, which
// reads back as 18446744073709551613.

pub fn main() i32 {
    let b: u64 = -3
    return b as i32
}
