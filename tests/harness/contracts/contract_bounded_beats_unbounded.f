//! TEST: contract_bounded_beats_unbounded
//! EXIT: 21

type Counter = struct {
    n: i32
}

fn next(self: &Counter) i32? {
    return null
}

type Iter = contract(T) {
    fn next(self: &Self) T?
}

// Same shape, one bounded: the bound that holds is the more specific overload.
fn describe(x: $X) i32 {
    return 1
}

fn describe(x: $X) i32 where X: Iter($T) {
    return 20
}

pub fn main() i32 {
    const c = Counter { n = 0 }
    return describe(c) + describe(5i32)
}
