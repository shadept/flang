//! TEST: unpinned_list_element_error
//! COMPILE-ERROR: E2001

import std.collections.list

// Nothing ever pins the element type, so the `deinit` pick cannot instantiate. The report belongs
// here, at the call, not inside list.f's element loop.
pub fn main() i32 {
    let xs = list(0)
    defer xs.deinit()
    return 0
}
