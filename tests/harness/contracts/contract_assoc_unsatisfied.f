//! TEST: contract_assoc_unsatisfied
//! COMPILE-ERROR: E2134
//! EXIT: 1

type Bag = struct {
    size: i32
}

// `iter` exists, but what it returns is no iterator.
fn iter(self: &Bag) i32 {
    return self.size
}

type Iterator = contract(T) {
    fn next(self: &Self) T?
}

type Iterable = contract(T) {
    type S: Iterator(T)
    fn iter(self: &Self) S
}

fn count(xs: &$C) i32 where C: Iterable($T) {
    return 0
}

pub fn main() i32 {
    const b = Bag { size = 0 }
    return count(&b) // error E2134
}
