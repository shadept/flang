//! TEST: for_releases_temporary_iterable
//! EXIT: 1

// A temporary iterable that `iter` only borrows has no owner past the statement: the loop releases
// it on exit, once.
type Bag = struct {
    owned released: &i32
    n: i32
}

type BagIter = struct {
    left: i32
}

pub fn deinit(self: move Bag) {
    self.released.* = self.released.* + 1
}

fn iter(self: &Bag) BagIter {
    return BagIter { left = self.n }
}

fn next(self: &BagIter) i32? {
    if self.left == 0 {
        return null
    }
    self.left = self.left - 1
    return Some(self.left)
}

fn bag(released: &i32, n: i32) Bag {
    return Bag { released = released, n = n }
}

pub fn main() i32 {
    let released: i32 = 0
    let seen: i32 = 0
    for _x in bag(&released, 3) {
        seen = seen + 1
    }
    if seen != 3 {
        return 9
    }
    return released
}
