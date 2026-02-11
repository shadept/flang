//! TEST: explicit_ref_mutation
//! EXIT: 0

// Explicit &T references allow callee to mutate caller's storage.
// Contrast with implicit pass-by-value semantics.

struct Counter {
    count: i32
}

fn increment(c: &Counter) {
    c.count = c.count + 1
}

fn add_n(c: &Counter, n: i32) {
    c.count = c.count + n
}

pub fn main() i32 {
    let c = Counter { count = 0 }

    increment(&c)
    if c.count != 1 { return 1 }

    increment(&c)
    increment(&c)
    if c.count != 3 { return 2 }

    add_n(&c, 10)
    if c.count != 13 { return 3 }

    return 0
}
