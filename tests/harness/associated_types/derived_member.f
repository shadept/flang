//! TEST: derived_member
//! EXIT: 7

import std.option

type Counter = struct {
    n: i32
    limit: i32
}

fn next(self: &Counter) i32? {
    if self.n >= self.limit {
        return null
    }
    self.n = self.n + 1
    return Some(self.n)
}

type Range3 = struct {
    start: i32
}

fn iter(self: &Range3) Counter {
    return Counter { n = self.start, limit = self.start + 3 }
}

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

// `Item` is derived from the iterator `iter` returns.
type Walk = contract {
    type It: Iter
    type Item = It.Item
    fn iter(self: &Self) It
}

fn first(xs: &$C) C.Item? where C: Walk {
    let it = xs.iter()
    return it.next()
}

// `C.It.Item` reads through `Walk` to its `Iter`; it is the same type as `C.Item`.
fn second(xs: &$C) C.It.Item? where C: Walk {
    let it = xs.iter()
    const _skip = it.next()
    return it.next()
}

pub fn main() i32 {
    const r = Range3 { start = 2 }
    return first(&r).unwrap() + second(&r).unwrap()
}
