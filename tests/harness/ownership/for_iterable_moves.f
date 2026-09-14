//! TEST: for_iterable_moves
//! COMPILE-ERROR: E2123
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

fn iter(self: move Bag) BagIter {
    return .{ left = self.n }
}

// `iter` takes ownership of its receiver, so the loop moves `b`.
pub fn main() i32 {
    let total = 0
    for x in make_bag() {
        total = total + x
    }
    let b = make_bag()
    for x in b {
        total = total + x
    }
    return total + b.n             // error E2123
}
