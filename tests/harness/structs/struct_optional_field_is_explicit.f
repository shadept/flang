//! TEST: struct_optional_field_is_explicit
//! EXIT: 7

// An optional field is a field: it is spelled out like any other rather than left to zero bytes.

import std.option

type Config = struct {
    value: i32
    name: String?
}

pub fn main() i32 {
    let c = Config { value = 7i32, name = null }
    if c.name.is_some() {
        return 1i32
    }
    return c.value
}
