//! TEST: two_contracts_one_item
//! EXIT: 4

import std.option

type Counter = struct {
    n: i32
}

fn next(self: &Counter) i32? {
    self.n = self.n + 1
    return Some(self.n)
}

fn peek(self: &Counter) i32 {
    return self.n + 1
}

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Peek = contract {
    type Item
    fn peek(self: &Self) Item
}

// Both contracts declare `Item`: on one parameter they name one type, so `peek`'s result and
// `next`'s element add.
fn both(it: move $I) I.Item where I: Iter + Peek, I.Item: copyable {
    const p = it.peek()
    const n = it.next().unwrap()
    return p + n
}

pub fn main() i32 {
    return both(Counter { n = 1 })
}
