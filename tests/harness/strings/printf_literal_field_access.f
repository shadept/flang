//! TEST: printf_literal_field_access
//! EXIT: 0
//! STDOUT: hello

import core.string

#foreign fn printf(fmt: &u8, len: i32, ptr: &u8) i32

pub fn main() i32 {
    printf("%.*s".ptr, 5, "hello".ptr)
    return 0
}
