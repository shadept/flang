//! TEST: struct_bounds_implied
//! EXIT: 30

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

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

// `F`'s bound reads `I.Item`, which `I`'s bound declares.
type Filtered = struct(I: Iter, F: fn(I.Item) bool) {
    it: I
    f: F
}

// No `where`: `I: Iter` and `F: fn(I.Item) bool` hold because the signature names `Filtered(I, F)`,
// and `I.Item` is in scope through them.
fn next(self: &Filtered($I, $F)) I.Item? {
    loop {
        const v = self.it.next()
        if v.is_none() {
            return null
        }
        const x = v.unwrap()
        if self.f(x) {
            return Some(move x)
        }
    }
}

// The return type implies the bounds too, so the lambda's parameter is typed from `I.Item`.
fn filter(it: move $I, f: move $F) Filtered(I, F) {
    return .{ it = move it, f = move f }
}

pub fn main() i32 {
    let evens = filter(Counter { n = 0, limit = 10 }, fn(x) { x % 2 == 0 })
    let sum: i32 = 0
    loop {
        const v = evens.next()
        if v.is_none() {
            break
        }
        sum = sum + v.unwrap()
    }
    return sum
}
