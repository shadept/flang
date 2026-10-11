//! TEST: contract_unsatisfied
//! COMPILE-ERROR: E2134
//! EXIT: 1

type Iter = contract(T) {
    fn next(self: &Self) T?
}

fn drain_all(it: move $I) where I: Iter($T) {}

pub fn main() i32 {
    drain_all(3i32) // error E2134: `i32` has no `next`
    return 0
}
