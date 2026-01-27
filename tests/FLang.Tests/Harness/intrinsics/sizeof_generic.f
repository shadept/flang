//! TEST: sizeof_generic
//! EXIT: 4

// Test size_of intrinsic with generic type parameter
// Expected: sizeof(T) where T=i32 should be 4 bytes

import core.rtti

fn get_size(x: $T) usize {
    return size_of(T)
}

pub fn main() i32 {
    let v: i32 = 0
    return get_size(v) as i32
}
