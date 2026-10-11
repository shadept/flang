//! TEST: projection_pinned
//! EXIT: 15

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

// `Item = i32` pins the element type: the body adds without knowing `I`.
fn total(it: move $I) i32 where I: Iter(Item = i32) {
    let sum: i32 = 0
    loop {
        const x = it.next()
        if x.is_none() {
            break
        }
        sum = sum + x.unwrap()
    }
    return sum
}

pub fn main() i32 {
    const c = Counter { n = 0, limit = 5 }
    return total(c)
}
