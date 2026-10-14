//! TEST: literal_to_enum_unknown_tag_error
//! COMPILE-ERROR: E2020

// An integer literal that no variant carries names no value of the enum, so the cast is refused.
// A runtime value is not checked.

type Month = enum {
    January = 1
    December = 12
}

pub fn main() i32 {
    const m = 13 as Month
    return 0
}
