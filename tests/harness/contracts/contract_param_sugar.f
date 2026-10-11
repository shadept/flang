//! TEST: contract_param_sugar
//! EXIT: 23

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

type Ones = struct {
    left: i32
}

fn next(self: &Ones) i32? {
    return Some(1)
}

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Same = contract {
    fn same(a: Self, b: Self) bool
}

fn same(a: i32, b: i32) bool {
    return a == b
}

// `it: move Iter(Item: Same)` is `it: move $I where I: Iter(Item: Same)`.
fn count_same(it: move Iter(Item: Same), x: i32) i32 {
    let n: i32 = 0
    loop {
        const v = it.next()
        if v.is_none() {
            break
        }
        if same(v.unwrap(), x) {
            n = n + 1
        }
    }
    return n
}

// Behind a reference too. Each occurrence is a type parameter of its own, so `a` and `b` may be
// iterators of different types.
fn advance_both(a: &Iter, b: &Iter) i32 {
    const _x = a.next()
    const _y = b.next()
    return 20
}

pub fn main() i32 {
    let c = Counter { n = 0, limit = 5 }
    let d = Ones { left = 0 }
    return count_same(Counter { n = 0, limit = 5 }, 3i32) + advance_both(&c, &d) + 2
}
