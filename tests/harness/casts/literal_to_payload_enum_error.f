//! TEST: literal_to_payload_enum_error
//! COMPILE-ERROR: E2020

// An unsuffixed literal cast to a payload-carrying enum is refused by the checker, as `1i32 as E`
// is.

type E = enum {
    A
    B(i32)
}

pub fn main() i32 {
    const e = 1 as E
    return 0
}
