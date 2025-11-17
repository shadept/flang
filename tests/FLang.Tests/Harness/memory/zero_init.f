//! TEST: zero_init
//! EXIT: 0

// Test zero-initialization of uninitialized variables

pub fn main() i32 {
    // Scalar should be zero-initialized
    let x: i32

    // Array should be zero-initialized
    let arr: [i32; 3]

    // All should be zero, so sum is 0
    return arr[0] + arr[1] + arr[2] + x
}
