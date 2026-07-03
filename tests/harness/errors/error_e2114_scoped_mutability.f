//! TEST: error_e2114_scoped_mutability
//! COMPILE-ERROR: E2114
//! EXIT: 1

// Writing to a field of a struct defined in another module is forbidden —
// the defining module owns its invariants. `List` is defined in
// `stdlib/std/list.f`, so its fields are read-only from any other file.

import std.list

pub fn main() i32 {
    let l: List(i32)
    l.len = 5                  // error E2114 — len is List's, not ours
    return 0
}
