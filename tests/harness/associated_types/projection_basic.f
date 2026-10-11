//! TEST: projection_basic
//! EXIT: 10

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

// `I.Item` is the element type `Counter`'s `next` solves, in a parameter and the return type;
// `I.Item: copyable` lets the body copy it.
fn last_or(it: move $I, fallback: I.Item) I.Item where I: Iter, I.Item: copyable {
    let out: I.Item = fallback
    loop {
        const x = it.next()
        if x.is_none() {
            break
        }
        out = x.unwrap()
    }
    return out
}

pub fn main() i32 {
    const c = Counter { n = 0, limit = 10 }
    return last_or(c, -1i32)
}
