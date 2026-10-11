//! TEST: contract_bound_filters_overload
//! EXIT: 12

type Counter = struct {
    n: i32
}

fn next(self: &Counter) i32? {
    if self.n >= 3 {
        return null
    }
    self.n = self.n + 1
    return Some(self.n)
}

type Bag = struct {
    size: i32
}

type Iter = contract(T) {
    fn next(self: &Self) T?
}

// A catch-all that would take any receiver as written; its bound keeps it to iterators.
fn size_of_it(it: move $I) i32 where I: Iter($T) {
    return 2
}

fn size_of_it(b: &Bag) i32 {
    return b.size
}

pub fn main() i32 {
    const b = Bag { size = 10 }
    const c = Counter { n = 0 }
    return b.size_of_it() + c.size_of_it()
}
