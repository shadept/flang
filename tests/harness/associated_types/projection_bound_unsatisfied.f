//! TEST: projection_bound_unsatisfied
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.option

type Point = struct {
    x: i32
}

type Points = struct {
    done: bool
}

fn next(self: &Points) Point? {
    return null
}

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Same = contract {
    fn same(a: Self, b: Self) bool
}

fn count(it: move $I) i32 where I: Iter(Item: Same) {
    return 0
}

pub fn main() i32 {
    const p = Points { done = false }
    return count(p) // error E2134: `Point` has no `same`
}
