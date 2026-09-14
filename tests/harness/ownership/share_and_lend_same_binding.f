//! TEST: share_and_lend_same_binding
//! COMPILE-ERROR: E2133
//! EXIT: 1

type Bag = struct {
    owned ptr: &i32
    len: i32
}

fn concat(self: &Bag, other: Bag) {
    self.len = self.len + other.len
}

// `concat` may grow `self` while it walks `other`: one owned buffer, shared and read at once.
pub fn main() i32 {
    let n: i32 = 1
    let b = Bag { ptr = &n, len = 1 }
    b.concat(b)                    // error E2133
    return b.len
}
