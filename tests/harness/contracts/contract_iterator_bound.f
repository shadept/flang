//! TEST: contract_iterator_bound
//! EXIT: 5

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

type Iter = contract(T) {
    fn next(self: &Self) T?
}

// `Iter($T)` solves `T` from `Counter`'s `next`; `F: fn(T) bool` types the lambda's parameter.
fn count_where(it: move $I, pred: $F) i32 where I: Iter($T), F: fn(T) bool {
    let n: i32 = 0
    loop {
        const x = it.next()
        if x.is_none() {
            break
        }
        if pred(x.unwrap()) {
            n = n + 1
        }
    }
    return n
}

pub fn main() i32 {
    const c = Counter { n = 0, limit = 10 }
    return count_where(c) { x => x % 2 == 0 }
}
