//! TEST: projection_errors
//! COMPILE-ERROR: E2142
//! COMPILE-ERROR: E2143
//! EXIT: 1

import std.option

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Point = struct {
    x: i32
}

fn missing(it: move $I) I.Elem? where I: Iter { // error E2142: no `Elem`
    return null
}

fn concrete(p: Point.Item) {} // error E2142: `Point` is no type parameter

fn unknown(it: move $I) where I: Iter(Elem = i32) {} // error E2143: no `Elem`

fn twice(it: move $I) where I: Iter(Item = i32, Item = u8) {} // error E2143: `Item` twice

fn outside(x: Point(Item = i32)) {} // error E2143: not in a bound

pub fn main() i32 {
    return 0
}
