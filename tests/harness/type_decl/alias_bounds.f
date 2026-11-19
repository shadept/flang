//! TEST: alias_bounds
//! EXIT: 42

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

type Scored = contract {
    fn score(self: &Self) i64
}

type Coin = struct {
    v: i64
}

fn score(self: &Coin) i64 {
    return self.v
}

type Board(T: Scored) = struct {
    item: T
}

// The aliased type's bound carries over unwritten.
type Shelf(T) = Board(T)

// The alias's own bound adds to it.
type Twin(T: copyable) = Board(T)

// A bound lets the body name what it provides.
type Pairs(I: Iter) = (I.Item, I.Item)

// `T: Scored` is implied by `Shelf(T)`.
fn total(b: &Shelf($T)) i64 {
    return b.item.score()
}

// `T: copyable` and `T: Scored` are implied by `Twin(T)`.
fn twice(b: &Twin($T)) (T, T) {
    return (b.item, b.item)
}

// `I: Iter` is implied by `Pairs(I)`, and with it `I.Item`.
fn pair_up(it: &$I) Pairs(I) {
    const a = it.next().unwrap()
    const b = it.next().unwrap()
    return (a, b)
}

pub fn main() i32 {
    const s: Shelf(Coin) = .{ item = Coin { v = 5 } }
    const t: Twin(Coin) = .{ item = Coin { v = 7 } }
    const xy = twice(&t)
    let c = Counter { n = 10, limit = 20 }
    const p: Pairs(Counter) = pair_up(&c)
    const sum: i64 = total(&s) + xy.0.score() + xy.1.score() + p.0 + p.1
    return sum as i32
}
