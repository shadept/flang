//! TEST: sizeof_basic
//! EXIT: 4

// Test size_of intrinsic with basic integer type
// Expected: sizeof(i32) = 4 bytes

pub fn main() i32 {
    return size_of(i32)
}
