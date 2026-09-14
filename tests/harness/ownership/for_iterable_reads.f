//! TEST: for_iterable_reads
//! COMPILE-ERROR: E2132
//! EXIT: 1

type Bag = struct {
    owned fd: i32
    n: i32
}

type BagIter = struct {
    left: i32
}

fn make_bag() Bag {
    return .{ fd = 1, n = 2 }
}

fn next(self: &BagIter) i32? {
    if self.left == 0 {
        return null
    }
    self.left = self.left - 1
    return Some(self.left)
}

fn iter(self: &Bag) BagIter {
    return .{ left = self.n }
}

// `for x in e` is `e.iter()`: a read-only receiver, so the temporary reaches no owner.
pub fn main() i32 {
    let total = 0
    for x in make_bag() {          // error E2132
        total = total + x
    }
    return total
}
