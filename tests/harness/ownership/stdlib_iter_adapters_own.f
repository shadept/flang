//! TEST: stdlib_iter_adapters_own
//! EXIT: 6

import std.collections.iter

// An iterator state that owns something: adapters and consumers take it over.
type Gen = struct {
    owned id: i32
    left: i32
}

fn gen(n: i32) Gen {
    return .{ id = 7, left = n }
}

pub fn iter(self: move Gen) Gen {
    return self
}

pub fn next(self: &Gen) i32? {
    if self.left == 0 {
        return null
    }
    self.left = self.left - 1
    return Some(self.left)
}

pub fn main() i32 {
    let total = 0
    for x in gen(4).filter(fn(v: i32) bool { return v % 2 == 1 }) {
        total = total + x
    }
    const n = gen(3).map(fn(v: i32) i32 { return v * 2 }).count()
    return total + (n as i32) - 1
}
