//! TEST: where_on_type
//! COMPILE-ERROR: E2145
//! EXIT: 1

type Wheres = struct(T) where T: copyable { // error E2145: the bound sits on the parameter
    x: T
}

pub fn main() i32 {
    return 0
}
