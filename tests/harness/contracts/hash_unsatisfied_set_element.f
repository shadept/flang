//! TEST: hash_unsatisfied_set_element
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.collections.set

// An element with `==` but no `hash`: owning, so the generic byte hash does not apply.
type Name = struct {
    owned id: i32
}

pub fn op_eq(a: Name, b: Name) bool {
    return a.id == b.id
}

pub fn deinit(self: move Name) {}

pub fn main() i32 {
    let s: Set(Name) = set()
    defer s.deinit()
    const _added = s.add(Name { id = 1 }) // error E2134: `Name` has no `hash`
    return 0
}
