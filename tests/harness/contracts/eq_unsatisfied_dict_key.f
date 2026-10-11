//! TEST: eq_unsatisfied_dict_key
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.collections.dict

// A key without `==` is refused at the call that picked it, naming the contract.
type Point = struct {
    x: i32
    y: i32
}

pub fn main() i32 {
    let d: Dict(Point, i32) = dict()
    defer d.deinit()
    d.set(Point { x = 1, y = 2 }, 3) // error E2134: `Point` has no `op_eq`
    return 0
}
