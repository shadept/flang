//! TEST: contract_assoc_type
//! EXIT: 3

import std.option

type Range3 = struct {
    n: i32
}

fn next(self: &Range3) i32? {
    if self.n >= 3 {
        return null
    }
    self.n = self.n + 1
    return Some(self.n)
}

type Bag = struct {
    size: i32
}

fn iter(self: &Bag) Range3 {
    return Range3 { n = 0 }
}

type Iterator = contract(T) {
    fn next(self: &Self) T?
}

// `S` is solved from `iter`'s return type, then held to its own bound.
type Iterable = contract(T) {
    type S: Iterator(T)
    fn iter(self: &Self) S
}

fn count(xs: &$C) i32 where C: Iterable($T) {
    let n: i32 = 0
    for x in xs {
        n = n + 1
    }
    return n
}

pub fn main() i32 {
    const b = Bag { size = 0 }
    return count(&b)
}
