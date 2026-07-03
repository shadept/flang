//! TEST: printf_literal_field_access
//! EXIT: 0
//! STDOUT: hello

import core.string

pub fn main() i32 {
    printf("%.*s".ptr, 5, "hello".ptr)
    return 0
}
