//! TEST: context_not_copyable
//! COMPILE-ERROR: E2147
//! EXIT: 1

import std.collections.list

const no_items: List(i32)? = null

context items: List(i32) = no_items // error E2147: a `List` owns its buffer

pub fn main() i32 {
    return 0
}
