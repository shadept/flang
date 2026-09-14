//! TEST: for_iterable_lent_param
//! COMPILE-ERROR: E2131
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

// The receiver adapts to `&Bag`, which shares a value the function only reads.
fn sum(b: Bag) i32 {
    let total = 0
    for x in b {                   // error E2131
        total = total + x
    }
    return total
}

pub fn main() i32 {
    let b = make_bag()
    return sum(b)
}
