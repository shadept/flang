//! TEST: bound_loses_to_concrete
//! EXIT: 11

type Counter = struct {
    n: i32
}

fn next(self: &Counter) i32? {
    return null
}

type Iter = contract(T) {
    fn next(self: &Self) T?
}

// A bound adds specificity against an unbounded type parameter, never against a concrete type.
fn which(c: Counter) i32 {
    return 10
}

fn which(x: $X) i32 where X: Iter($T) {
    return 20
}

fn which(x: i32) i32 {
    return 1
}

pub fn main() i32 {
    const c = Counter { n = 0 }
    return which(c) + which(5i32)
}
