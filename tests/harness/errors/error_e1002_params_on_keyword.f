//! TEST: error_e1002_params_on_keyword
//! COMPILE-ERROR: E1002

// Type parameters go on the name, not the keyword (RFC-047).
type Pair = struct(T) { // error[E1002]
    a: T
    b: T
}

type Tagged = enum(T) { // error[E1002]
    Tag(T)
}

type Shows = contract(T) { // error[E1002]
    fn show(self: &Self, v: T) i32
}

pub fn main() i32 {
    return 0
}
