//! TEST: field_projection
//! EXIT: 40

import std.option

type Counter = struct {
    n: i64
    limit: i64
}

fn next(self: &Counter) i64? {
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

// A field typed by the parameter's associated type: `Peekable(Counter)` stores an `i64?`.
type Peekable = struct(I: Iter) {
    it: I
    peeked: I.Item?
}

fn peekable(it: move $I) Peekable(I) {
    return .{ it = move it, peeked = null }
}

fn peek(self: &Peekable($I)) I.Item? where I.Item: copyable {
    if self.peeked.is_none() {
        self.peeked = self.it.next()
    }
    return self.peeked
}

fn next(self: &Peekable($I)) I.Item? where I.Item: copyable {
    const p = self.peeked
    if p.is_some() {
        self.peeked = null
        return p
    }
    return self.it.next()
}

// An enum payload projects the same way.
type Step = enum(I: Iter) {
    Done
    Got(I.Item)
}

fn step(it: &$I) Step(I) where I: Iter {
    const v = it.next()
    if v.is_none() {
        return Step.Done
    }
    return Step.Got(v.unwrap())
}

pub fn main() i32 {
    let p = peekable(Counter { n = 0, limit = 5 })
    const a = p.peek().unwrap()
    const b = p.peek().unwrap()
    const c = p.next().unwrap()
    const d = p.next().unwrap()
    const size_ok = size_of(Peekable(Counter)) == size_of(Counter) + size_of(Option(i64))
    let c2 = Counter { n = 30, limit = 40 }
    const s = step(&c2) match {
        Got(x) => x
        Done => 0i64
    }
    if !size_ok {
        return 1
    }
    return (a + b + c + d + s + 4i64) as i32
}
