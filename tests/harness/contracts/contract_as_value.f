//! TEST: contract_as_value
//! COMPILE-ERROR: E2138
//! EXIT: 1

type Reader = contract {
    fn read(self: &Self) i32
}

type Holder = struct {
    r: Reader // error E2138
}

pub fn main() i32 {
    return 0
}
