//! TEST: op_cmp_auto_lt
//! EXIT: 1

// Test auto-deriving op_lt from op_cmp

enum Ord {
    Less = -1
    Equal = 0
    Greater = 1
}

struct Box {
    size: i32
}

pub fn op_cmp(lhs: Box, rhs: Box) Ord {
    return if (lhs.size < rhs.size) Ord.Less
        else if (lhs.size > rhs.size) Ord.Greater
        else Ord.Equal
}

pub fn main() i32 {
    let small: Box = Box { size = 5 }
    let large: Box = Box { size = 10 }

    // op_lt is not defined, should auto-derive from op_cmp
    return if (small < large) 1 else 0
}
