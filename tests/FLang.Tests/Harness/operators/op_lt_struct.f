//! TEST: op_lt_struct
//! EXIT: 1

// Test operator overloading with op_lt for a custom struct type

struct Box {
    size: i32
}

// Define op_lt for Box (compare by size)
pub fn op_lt(lhs: Box, rhs: Box) bool {
    return lhs.size < rhs.size
}

pub fn main() i32 {
    let small: Box = Box { size = 5 }
    let large: Box = Box { size = 10 }

    // This should use our op_lt function
    return if (small < large) 1 else 0
}
