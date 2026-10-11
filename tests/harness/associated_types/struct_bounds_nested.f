//! TEST: struct_bounds_nested
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

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Source = struct(I: Iter) {
    it: I
}

type Holder = struct(T) {
    inner: T
}

// The bound of `Source` holds two levels down: `I.Item` reads through `Holder(Source(I))`.
fn pull(h: &Holder(Source($I))) I.Item? {
    return h.inner.it.next()
}

pub fn main() i32 {
    let h: Holder(Source(Counter)) = .{ inner = .{ it = Counter { n = 6, limit = 9 } } }
    const v = pull(&h)
    return v.unwrap()
}
