//! TEST: projection_bounded
//! EXIT: 2

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

type Same = contract {
    fn same(a: Self, b: Self) bool
}

fn same(a: i32, b: i32) bool {
    return a == b
}

// `Item: Same` bounds the element type; `where I.Item: Same` says the same.
fn count_of(it: move $I, x: I.Item) i32 where I: Iter(Item: Same) {
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

fn has(it: move $I, x: I.Item) i32 where I: Iter, I.Item: Same {
    return count_of(it, x)
}

pub fn main() i32 {
    const a = Counter { n = 0, limit = 5 }
    const b = Counter { n = 0, limit = 5 }
    return count_of(a, 3i32) + has(b, 4i32)
}
