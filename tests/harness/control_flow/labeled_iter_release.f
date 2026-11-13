//! TEST: labeled_iter_release
//! EXIT: 51

// `break outer` and `continue outer` release the iterators of the loops they leave, once each;
// `continue outer` keeps the outer loop's own.
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
    let inner: i32 = 0
    outer: for i in 0..3 as i32 {
        for _x in bag(&inner, 3) {
            if i == 2 {
                break outer
            }
            continue outer
        }
    }
    let outer_released: i32 = 0
    let rounds: i32 = 0
    rounds: for _y in bag(&outer_released, 2) {
        rounds = rounds + 1
        for _x in bag(&inner, 1) {
            continue rounds
        }
    }
    if rounds != 2 {
        return 9
    }
    return inner * 10 + outer_released
}
