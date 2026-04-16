//! TEST: int_to_payload_enum_error
//! COMPILE-ERROR: E2020

// Casting an integer to an enum that has any payload-carrying variant is
// rejected — the resulting payload bytes would be uninitialized.

type E = enum {
    A
    B(i32)
    C
}

pub fn main() i32 {
    const e = 1i32 as E
    return 0
}
