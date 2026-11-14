//! TEST: error_e2161_union_member
//! COMPILE-ERROR: E2161

// A union has no tag, so a member a release would have to run on cannot be told apart.

type Slot = #foreign union {
    i: i32
    owned p: &u8
}

pub fn main() i32 {
    return 0
}
