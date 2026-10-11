//! TEST: eq_unsatisfied_dict_key
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.collections.dict

// A key without `==` is refused where the dict type is written, naming the contract (RFC-036).
type Point = struct {
    x: i32
    y: i32
}

pub fn main() i32 {
    let d: Dict(Point, i32) = dict() // error E2134: `Point` has no `op_eq`
    defer d.deinit()
    d.set(Point { x = 1, y = 2 }, 3)
    return 0
}
